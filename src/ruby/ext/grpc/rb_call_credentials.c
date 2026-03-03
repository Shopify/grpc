/*
 *
 * Copyright 2015 gRPC authors.
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

#include "rb_call_credentials.h"

#include <grpc/credentials.h>
#include <grpc/grpc.h>
#include <grpc/grpc_security.h>
#include <grpc/support/alloc.h>
#include <grpc/support/log.h>
#include <grpc/support/sync.h>
#include <ruby/thread.h>

#include "rb_call.h"
#include "rb_event_thread.h"
#include "rb_grpc.h"
#include "rb_grpc_imports.generated.h"

/* grpc_rb_cCallCredentials is the ruby class that proxies
 * grpc_call_credentials */
static VALUE grpc_rb_cCallCredentials = Qnil;

/* plugin_ref ties the lifetime of a Ruby proc used as a gRPC credentials
 * plugin callback to the lifetime of the underlying C plugin, rather than
 * to the Ruby wrapper object. This prevents use-after-free when the Ruby
 * Channel/CallCredentials objects are GC'd but gRPC's C core still holds
 * a reference to the plugin and may invoke its callback. */
typedef struct plugin_ref {
  VALUE proc;
  struct plugin_ref* next;
} plugin_ref;

static plugin_ref* active_plugins_states = NULL;
static gpr_mu active_plugins_states_mu;

/* Register a proc as a value to mark for as long as its C plugin is alive. */
static plugin_ref* pin_plugin_proc(VALUE proc) {
  plugin_ref* ref = gpr_zalloc(sizeof(plugin_ref));
  ref->proc = proc;
  gpr_mu_lock(&active_plugins_states_mu);
  ref->next = active_plugins_states;
  active_plugins_states = ref;
  gpr_mu_unlock(&active_plugins_states_mu);
  return ref;
}

/* Remove a proc from the GC root set when its C plugin is destroyed.
 * Safe to call from any thread (does not require the GIL). */
static void unpin_plugin_proc(plugin_ref* ref) {
  gpr_mu_lock(&active_plugins_states_mu);
  plugin_ref** pp = &active_plugins_states;
  while (*pp) {
    if (*pp == ref) {
      *pp = ref->next;
      break;
    }
    pp = &(*pp)->next;
  }
  gpr_mu_unlock(&active_plugins_states_mu);
  gpr_free(ref);
}

/* GC mark callback for the global plugin marker object. Marks all procs
 * that are currently in use by active C-level credential plugins. */
static void grpc_rb_plugin_marker_mark(void* _unused) {
  (void)_unused;
  gpr_mu_lock(&active_plugins_states_mu);
  for (plugin_ref* ref = active_plugins_states; ref; ref = ref->next) {
    rb_gc_mark(ref->proc);
  }
  gpr_mu_unlock(&active_plugins_states_mu);
}

static const rb_data_type_t grpc_plugin_marker_type = {
    .wrap_struct_name = "grpc_plugin_marker",
    .function = {.dmark = grpc_rb_plugin_marker_mark,
                 .dfree = GRPC_RB_GC_DONT_FREE,
                 .dsize = GRPC_RB_MEMSIZE_UNAVAILABLE},
    .flags = 0,
};

/* grpc_rb_call_credentials wraps a grpc_call_credentials. It provides a mark
 * object that is used to hold references to any objects used to create the
 * credentials. */
typedef struct grpc_rb_call_credentials {
  /* Holder of ruby objects involved in contructing the credentials */
  VALUE mark;

  /* The actual credentials */
  grpc_call_credentials* wrapped;
} grpc_rb_call_credentials;

typedef struct callback_params {
  VALUE get_metadata;
  grpc_auth_metadata_context context;
  void* user_data;
  grpc_credentials_plugin_metadata_cb callback;
} callback_params;

static VALUE grpc_rb_call_credentials_callback(VALUE args) {
  VALUE result = rb_hash_new();
  VALUE callback_func = rb_ary_entry(args, 0);
  VALUE callback_args = rb_ary_entry(args, 1);
  VALUE md_ary_obj = rb_ary_entry(args, 2);

  VALUE callback_func_str = rb_funcall(callback_func, rb_intern("to_s"), 0);
  VALUE callback_args_str = rb_funcall(callback_args, rb_intern("to_s"), 0);
  VALUE callback_source_info =
      rb_funcall(callback_func, rb_intern("source_location"), 0);

  grpc_absl_log_str(
      GPR_DEBUG, "GRPC_RUBY: grpc_rb_call_credentials invoking user callback:",
      StringValueCStr(callback_func_str));

  if (callback_source_info != Qnil) {
    VALUE source_filename = rb_ary_entry(callback_source_info, 0);
    VALUE source_line_number =
        rb_funcall(rb_ary_entry(callback_source_info, 1), rb_intern("to_s"), 0);
    grpc_absl_log_str(GPR_DEBUG, "GRPC_RUBY: source_filename: ",
                      StringValueCStr(source_filename));
    grpc_absl_log_str(GPR_DEBUG, "GRPC_RUBY: source_line_number: ",
                      StringValueCStr(source_line_number));
    grpc_absl_log_str(GPR_DEBUG, "GRPC_RUBY: Arguments: ",
                      StringValueCStr(callback_args_str));
  } else {
    grpc_absl_log_str(
        GPR_DEBUG, "(failed to get source filename and line) with arguments: ",
        StringValueCStr(callback_args_str));
  }

  VALUE metadata =
      rb_funcall(callback_func, rb_intern("call"), 1, callback_args);
  grpc_metadata_array* md_ary = NULL;
  TypedData_Get_Struct(md_ary_obj, grpc_metadata_array,
                       &grpc_rb_md_ary_data_type, md_ary);
  grpc_rb_md_ary_convert(metadata, md_ary);
  rb_hash_aset(result, rb_str_new2("metadata"), metadata);
  rb_hash_aset(result, rb_str_new2("status"), INT2NUM(GRPC_STATUS_OK));
  rb_hash_aset(result, rb_str_new2("details"), rb_str_new2(""));
  return result;
}

static VALUE grpc_rb_call_credentials_callback_rescue(VALUE args,
                                                      VALUE exception_object) {
  VALUE result = rb_hash_new();
  VALUE backtrace = rb_funcall(exception_object, rb_intern("backtrace"), 0);
  VALUE backtrace_str;
  if (backtrace != Qnil) {
    backtrace_str =
        rb_funcall(backtrace, rb_intern("join"), 1, rb_str_new2("\n\tfrom "));
  } else {
    backtrace_str = rb_str_new2(
        "failed to get backtrace, this exception was likely thrown from native "
        "code");
  }
  VALUE rb_exception_info =
      rb_funcall(exception_object, rb_intern("inspect"), 0);
  (void)args;

  grpc_absl_log_str(
      GPR_DEBUG,
      "GRPC_RUBY call credentials callback failed, exception inspect: ",
      StringValueCStr(rb_exception_info));
  grpc_absl_log_str(GPR_DEBUG,
                    "GRPC_RUBY call credentials callback failed, backtrace: ",
                    StringValueCStr(backtrace_str));

  rb_hash_aset(result, rb_str_new2("metadata"), Qnil);
  rb_hash_aset(result, rb_str_new2("status"),
               INT2NUM(GRPC_STATUS_UNAUTHENTICATED));
  rb_hash_aset(result, rb_str_new2("details"), rb_exception_info);
  return result;
}

static void grpc_rb_call_credentials_callback_with_gil(void* param) {
  callback_params* const params = (callback_params*)param;
  VALUE auth_uri = rb_str_new_cstr(params->context.service_url);
  /* Pass the arguments to the proc in a hash, which currently only has they key
     'auth_uri' */
  VALUE callback_args = rb_ary_new();
  VALUE args = rb_hash_new();
  VALUE result;
  grpc_metadata_array md_ary;
  grpc_status_code status;
  VALUE details;
  char* error_details;
  grpc_metadata_array_init(&md_ary);
  rb_hash_aset(args, ID2SYM(rb_intern("jwt_aud_uri")), auth_uri);
  rb_ary_push(callback_args, params->get_metadata);
  rb_ary_push(callback_args, args);
  // Wrap up the grpc_metadata_array into a ruby object and do the conversion
  // from hash to grpc_metadata_array within the rescue block, because the
  // conversion can throw exceptions.
  rb_ary_push(callback_args,
              TypedData_Wrap_Struct(grpc_rb_cMdAry, &grpc_rb_md_ary_data_type,
                                    &md_ary));
  result = rb_rescue(grpc_rb_call_credentials_callback, callback_args,
                     grpc_rb_call_credentials_callback_rescue, Qnil);
  // Both callbacks return a hash, so result should be a hash
  status = NUM2INT(rb_hash_aref(result, rb_str_new2("status")));
  details = rb_hash_aref(result, rb_str_new2("details"));
  error_details = StringValueCStr(details);
  params->callback(params->user_data, md_ary.metadata, md_ary.count, status,
                   error_details);
  grpc_rb_metadata_array_destroy_including_entries(&md_ary);
  grpc_auth_metadata_context_reset(&params->context);
  gpr_free(params);
}

static int grpc_rb_call_credentials_plugin_get_metadata(
    void* state, grpc_auth_metadata_context context,
    grpc_credentials_plugin_metadata_cb cb, void* user_data,
    grpc_metadata creds_md[GRPC_METADATA_CREDENTIALS_PLUGIN_SYNC_MAX],
    size_t* num_creds_md, grpc_status_code* status,
    const char** error_details) {
  callback_params* params = gpr_zalloc(sizeof(callback_params));
  params->get_metadata = ((plugin_ref*)state)->proc;
  grpc_auth_metadata_context_copy(&context, &params->context);
  params->user_data = user_data;
  params->callback = cb;

  grpc_rb_event_queue_enqueue(grpc_rb_call_credentials_callback_with_gil,
                              (void*)(params));
  return 0;  // Async return.
}

static void grpc_rb_call_credentials_plugin_destroy(void* state) {
  if (state != NULL) {
    unpin_plugin_proc((plugin_ref*)state);
  }
}

static void grpc_rb_call_credentials_free_internal(void* p) {
  grpc_rb_call_credentials* wrapper;
  if (p == NULL) {
    return;
  }
  wrapper = (grpc_rb_call_credentials*)p;
  grpc_call_credentials_release(wrapper->wrapped);
  wrapper->wrapped = NULL;
  xfree(p);
}

/* Destroys the credentials instances. */
static void grpc_rb_call_credentials_free(void* p) {
  grpc_rb_call_credentials_free_internal(p);
}

/* Protects the mark object from GC */
static void grpc_rb_call_credentials_mark(void* p) {
  grpc_rb_call_credentials* wrapper = NULL;
  if (p == NULL) {
    return;
  }
  wrapper = (grpc_rb_call_credentials*)p;
  if (wrapper->mark != Qnil) {
    rb_gc_mark(wrapper->mark);
  }
}

static rb_data_type_t grpc_rb_call_credentials_data_type = {
    "grpc_call_credentials",
    {grpc_rb_call_credentials_mark,
     grpc_rb_call_credentials_free,
     GRPC_RB_MEMSIZE_UNAVAILABLE,
     {NULL, NULL}},
    NULL,
    NULL,
#ifdef RUBY_TYPED_FREE_IMMEDIATELY
    RUBY_TYPED_FREE_IMMEDIATELY
#endif
};

/* Allocates CallCredentials instances.
   Provides safe initial defaults for the instance fields. */
static VALUE grpc_rb_call_credentials_alloc(VALUE cls) {
  grpc_ruby_init();
  grpc_rb_call_credentials* wrapper = ALLOC(grpc_rb_call_credentials);
  wrapper->wrapped = NULL;
  wrapper->mark = Qnil;
  return TypedData_Wrap_Struct(cls, &grpc_rb_call_credentials_data_type,
                               wrapper);
}

/* Creates a wrapping object for a given call credentials. This should only be
 * called with grpc_call_credentials objects that are not already associated
 * with any Ruby object */
VALUE grpc_rb_wrap_call_credentials(grpc_call_credentials* c, VALUE mark) {
  VALUE rb_wrapper;
  grpc_rb_call_credentials* wrapper;
  if (c == NULL) {
    return Qnil;
  }
  rb_wrapper = grpc_rb_call_credentials_alloc(grpc_rb_cCallCredentials);
  TypedData_Get_Struct(rb_wrapper, grpc_rb_call_credentials,
                       &grpc_rb_call_credentials_data_type, wrapper);
  wrapper->wrapped = c;
  wrapper->mark = mark;
  return rb_wrapper;
}

/* The attribute used on the mark object to hold the callback */
static ID id_callback;

/*
  call-seq:
    creds = Credentials.new auth_proc
  proc: (required) Proc that generates auth metadata
  Initializes CallCredential instances. */
static VALUE grpc_rb_call_credentials_init(VALUE self, VALUE proc) {
  grpc_rb_call_credentials* wrapper = NULL;
  grpc_call_credentials* creds = NULL;
  grpc_metadata_credentials_plugin plugin;

  TypedData_Get_Struct(self, grpc_rb_call_credentials,
                       &grpc_rb_call_credentials_data_type, wrapper);

  plugin.get_metadata = grpc_rb_call_credentials_plugin_get_metadata;
  plugin.destroy = grpc_rb_call_credentials_plugin_destroy;
  if (!rb_obj_is_proc(proc)) {
    rb_raise(rb_eTypeError, "Argument to CallCredentials#new must be a proc");
    return Qnil;
  }
  plugin_ref* ref = pin_plugin_proc(proc);
  plugin.state = (void*)ref;
  plugin.type = "";

  // TODO(yihuazhang): Expose min_security_level via the Ruby API so that
  // applications can decide what minimum security level their plugins require.
  creds = grpc_metadata_credentials_create_from_plugin(
      plugin, GRPC_PRIVACY_AND_INTEGRITY, NULL);
  if (creds == NULL) {
    unpin_plugin_proc(ref);
    rb_raise(rb_eRuntimeError, "could not create a credentials, not sure why");
    return Qnil;
  }

  wrapper->mark = proc;
  wrapper->wrapped = creds;
  rb_ivar_set(self, id_callback, proc);

  return self;
}

static VALUE grpc_rb_call_credentials_compose(int argc, VALUE* argv,
                                              VALUE self) {
  grpc_call_credentials* creds;
  grpc_call_credentials* other;
  grpc_call_credentials* prev = NULL;
  VALUE mark;
  if (argc == 0) {
    return self;
  }
  mark = rb_ary_new();
  creds = grpc_rb_get_wrapped_call_credentials(self);
  for (int i = 0; i < argc; i++) {
    rb_ary_push(mark, argv[i]);
    other = grpc_rb_get_wrapped_call_credentials(argv[i]);
    creds = grpc_composite_call_credentials_create(creds, other, NULL);
    if (prev != NULL) {
      grpc_call_credentials_release(prev);
    }
    prev = creds;
  }
  return grpc_rb_wrap_call_credentials(creds, mark);
}

void Init_grpc_call_credentials() {
  grpc_rb_cCallCredentials =
      rb_define_class_under(grpc_rb_mGrpcCore, "CallCredentials", rb_cObject);

  /* Allocates an object managed by the ruby runtime */
  rb_define_alloc_func(grpc_rb_cCallCredentials,
                       grpc_rb_call_credentials_alloc);

  /* Provides a ruby constructor and support for dup/clone. */
  rb_define_method(grpc_rb_cCallCredentials, "initialize",
                   grpc_rb_call_credentials_init, 1);
  rb_define_method(grpc_rb_cCallCredentials, "initialize_copy",
                   grpc_rb_cannot_init_copy, 1);
  rb_define_method(grpc_rb_cCallCredentials, "compose",
                   grpc_rb_call_credentials_compose, -1);

  id_callback = rb_intern("__callback");

  /* Initialize the mutex protecting the active plugin list. */
  gpr_mu_init(&active_plugins_states_mu);

  /* Create a global marker object whose mark and compact callbacks keep
   * plugin procs alive for as long as their C-level plugins exist.
   * Stored as an ivar on the class (a GC root via the constant table)
   * so the marker stays alive without rb_gc_register_address. */
  VALUE plugin_marker = TypedData_Wrap_Struct(
      rb_cObject, &grpc_plugin_marker_type, &active_plugins_states);
  rb_ivar_set(grpc_rb_cCallCredentials, rb_intern("__plugin_marker"),
              plugin_marker);
}

/* Reset the active plugin states list after fork in the child process.
 * After fork, the C core resets its own state, so the old plugin_destroy
 * callbacks are never called. We must clear the inherited list to avoid
 * marking stale proc references. The mutex does not need reinit because
 * GRPC.prefork ensures all gRPC threads are stopped before fork, so it
 * is guaranteed to be in an unlocked state. */
void grpc_rb_call_credentials_postfork_child() {
  plugin_ref* ref = active_plugins_states;
  active_plugins_states = NULL;
  while (ref) {
    plugin_ref* next = ref->next;
    gpr_free(ref);
    ref = next;
  }
}

/* Gets the wrapped grpc_call_credentials from the ruby wrapper */
grpc_call_credentials* grpc_rb_get_wrapped_call_credentials(VALUE v) {
  grpc_rb_call_credentials* wrapper = NULL;
  TypedData_Get_Struct(v, grpc_rb_call_credentials,
                       &grpc_rb_call_credentials_data_type, wrapper);
  return wrapper->wrapped;
}
