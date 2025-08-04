/*
 *
 * Copyright 2016 gRPC authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#include <ruby/ruby.h>

#include "rb_event_thread.h"

#include <grpc/support/alloc.h>
#include <grpc/support/log.h>
#include <grpc/support/sync.h>
#include <grpc/support/time.h>
#include <ruby/thread.h>
#include <stdbool.h>
#include <string.h>
#ifdef __GLIBC__
#include <execinfo.h>
#include <dlfcn.h>
#endif

#include "rb_grpc.h"
#include "rb_grpc_imports.generated.h"

typedef struct grpc_rb_event {
  // callback will be called with argument while holding the GVL
  void (*callback)(void*);
  void* argument;

  struct grpc_rb_event* next;
  pid_t pid;
  char* c_backtrace;
} grpc_rb_event;

typedef struct grpc_rb_event_queue {
  grpc_rb_event* head;
  grpc_rb_event* tail;

  gpr_mu mu;
  gpr_cv cv;

  // Indicates that the thread should stop waiting
  bool abort;
} grpc_rb_event_queue;

static grpc_rb_event_queue event_queue;
static VALUE g_event_thread = Qnil;
static bool g_one_time_init_done = false;

void grpc_rb_event_queue_enqueue(void (*callback)(void*), void* argument) {
  grpc_rb_event* event = gpr_malloc(sizeof(grpc_rb_event));
  event->callback = callback;
  event->argument = argument;
  event->pid = getpid();

  // Capture C backtrace with enhanced formatting and debug symbols
#ifdef __GLIBC__
  void* buffer[32];  // Reduced for cleaner output with source info
  int nptrs = backtrace(buffer, 32);
  char** strings = backtrace_symbols(buffer, nptrs);
  if (strings != NULL && nptrs > 0) {
    size_t total_len = 200; // Header space
    for (int i = 0; i < nptrs; i++) {
      total_len += 1024; // Much more space for source file info
    }
    event->c_backtrace = gpr_malloc(total_len);
    snprintf(event->c_backtrace, total_len, "C Stack Trace (%d frames):\n", nptrs);
    
    for (int i = 0; i < nptrs; i++) {
      char frame_info[1024];
      void* addr = buffer[i];
      Dl_info dlinfo;
      
      // Use dladdr for better symbol resolution
      if (dladdr(addr, &dlinfo)) {
        const char* fname = dlinfo.dli_fname ? dlinfo.dli_fname : "??";
        const char* sname = dlinfo.dli_sname ? dlinfo.dli_sname : "??";
        
        // Try to get source file and line using addr2line
        char cmd[512];
        char source_info[256] = "";
        
        if (dlinfo.dli_fname) {
          // Calculate offset from base address
          void* offset = (void*)((char*)addr - (char*)dlinfo.dli_fbase);
          snprintf(cmd, sizeof(cmd), "addr2line -e %s -f -C %p 2>/dev/null", 
                  dlinfo.dli_fname, offset);
          
          FILE* fp = popen(cmd, "r");
          if (fp) {
            char func_line[128];
            char file_line[128];
            if (fgets(func_line, sizeof(func_line), fp) && 
                fgets(file_line, sizeof(file_line), fp)) {
              // Remove newlines
              func_line[strcspn(func_line, "\n")] = 0;
              file_line[strcspn(file_line, "\n")] = 0;
              
              if (strcmp(file_line, "??:0") != 0) {
                snprintf(source_info, sizeof(source_info), " at %s", file_line);
              }
            }
            pclose(fp);
          }
        }
        
        snprintf(frame_info, sizeof(frame_info), 
                "#%-2d %p in %s (%s)%s\n", 
                i, addr, sname, fname, source_info);
      } else {
        // Fallback to backtrace_symbols output
        snprintf(frame_info, sizeof(frame_info), "#%-2d %p (%s)\n", 
                i, addr, strings[i]);
      }
      strncat(event->c_backtrace, frame_info, total_len - strlen(event->c_backtrace) - 1);
    }
    free(strings);
  } else {
    event->c_backtrace = gpr_malloc(strlen("no C backtrace available") + 1);
    strcpy(event->c_backtrace, "no C backtrace available");
  }
#else
  event->c_backtrace = gpr_malloc(strlen("C backtrace not supported on this platform") + 1);
  strcpy(event->c_backtrace, "C backtrace not supported on this platform");
#endif

  event->next = NULL;
  gpr_mu_lock(&event_queue.mu);
  if (event_queue.tail == NULL) {
    event_queue.head = event_queue.tail = event;
  } else {
    event_queue.tail->next = event;
    event_queue.tail = event;
  }
  gpr_cv_signal(&event_queue.cv);
  gpr_mu_unlock(&event_queue.mu);
}

static grpc_rb_event* grpc_rb_event_queue_dequeue() {
  grpc_rb_event* event;
  if (event_queue.head == NULL) {
    event = NULL;
  } else {
    event = event_queue.head;
    if (event_queue.head->next == NULL) {
      event_queue.head = event_queue.tail = NULL;
    } else {
      event_queue.head = event_queue.head->next;
    }
  }
  if (event != NULL) {
    fprintf(stderr, "DEQUEUED EVENT PID %d %s CURRENT PID %d\nC BACKTRACE:\n%s\n",
            event->pid, (event->pid == getpid() ? "==" : "!="), getpid(), 
            event->c_backtrace);
  }
  else {
    fprintf(stderr, "DEQUEUED EVENT IS NULL\n");
  }
  return event;
}

static void grpc_rb_event_queue_destroy() {
  gpr_mu_destroy(&event_queue.mu);
  gpr_cv_destroy(&event_queue.cv);
}

static void* grpc_rb_wait_for_event_no_gil(void* param) {
  grpc_rb_event* event = NULL;
  (void)param;
  gpr_mu_lock(&event_queue.mu);
  while (!event_queue.abort) {
    if ((event = grpc_rb_event_queue_dequeue()) != NULL) {
      gpr_mu_unlock(&event_queue.mu);
      return event;
    }
    gpr_cv_wait(&event_queue.cv, &event_queue.mu,
                gpr_inf_future(GPR_CLOCK_REALTIME));
  }
  gpr_mu_unlock(&event_queue.mu);
  return NULL;
}

static void* grpc_rb_event_unblocking_func_wrapper(void* arg) {
  (void)arg;
  gpr_mu_lock(&event_queue.mu);
  event_queue.abort = true;
  gpr_cv_signal(&event_queue.cv);
  gpr_mu_unlock(&event_queue.mu);
  return NULL;
}

static void grpc_rb_event_unblocking_func(void* arg) {
  grpc_rb_event_unblocking_func_wrapper(arg);
}

/* This is the implementation of the thread that handles auth metadata plugin
 * events */
static VALUE grpc_rb_event_thread(void* arg) {
  grpc_rb_event* event;
  (void)arg;
  while (true) {
    event = (grpc_rb_event*)rb_thread_call_without_gvl(
        grpc_rb_wait_for_event_no_gil, NULL, grpc_rb_event_unblocking_func,
        NULL);
    if (event == NULL) {
      // Indicates that the thread needs to shut down
      break;
    } else {
      event->callback(event->argument);
      gpr_free(event->c_backtrace);
      gpr_free(event);
    }
  }
  grpc_rb_event_queue_destroy();
  return Qnil;
}

void grpc_rb_event_queue_thread_start() {
  if (!g_one_time_init_done) {
    g_one_time_init_done = true;
    gpr_mu_init(&event_queue.mu);
    gpr_cv_init(&event_queue.cv);
    rb_global_variable(&g_event_thread);
    event_queue.head = event_queue.tail = NULL;
  }
  event_queue.abort = false;
  GRPC_RUBY_ASSERT(!RTEST(g_event_thread));
  g_event_thread = rb_thread_create(grpc_rb_event_thread, NULL);
}

void grpc_rb_event_queue_thread_stop() {
  GRPC_RUBY_ASSERT(g_one_time_init_done);
  if (!RTEST(g_event_thread)) {
    grpc_absl_log(
        GPR_ERROR,
        "GRPC_RUBY: call credentials thread stop: thread not running");
    return;
  }
  rb_thread_call_without_gvl(grpc_rb_event_unblocking_func_wrapper, NULL, NULL,
                             NULL);
  rb_funcall(g_event_thread, rb_intern("join"), 0);
  g_event_thread = Qnil;
}
