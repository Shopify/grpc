[![Gem](https://img.shields.io/gem/v/grpc.svg)](https://rubygems.org/gems/grpc/)
gRPC Ruby
=========

A Ruby implementation of gRPC.

PREREQUISITES
-------------

- Ruby 3.x-4.x. The gRPC API uses keyword args.

INSTALLATION
---------------

**Linux and Mac OS X:**

```sh
gem install grpc
```

gRPC Ruby is implemented entirely in Ruby; the gem has no native extension and
nothing needs to be compiled at install time.

If using a Gemfile and you wish to pull from a git repository or GitHub:
```
gem 'grpc', github: 'grpc/grpc'
```

BUILD FROM SOURCE
---------------------
- Clone this repository

- Install Ruby. Consider doing this with [RVM](http://rvm.io), it's a nice way of controlling
  the exact ruby version that's used.
```sh
$ command curl -sSL https://rvm.io/mpapis.asc | gpg --import -
$ \curl -sSL https://get.rvm.io | bash -s stable --ruby=ruby-3
$
$ # follow the instructions to ensure that your're using the latest stable version of Ruby
$ # and that the rvm command is installed
```
- Make sure your run `source $HOME/.rvm/scripts/rvm` as instructed to complete the set up of RVM

- Finally,  build and install the gRPC gem locally.
```sh
$ # from this directory
$ bundle install  # creates the ruby bundle
$ rake  # runs the unit tests, see rake -T for other options
```

DOCUMENTATION
-------------
- rubydoc for the gRPC gem is available online at [rubydoc][].
- the gRPC Ruby reference documentation is available online at [grpc.io][]

CONTENTS
--------
- lib: the entrypoint gRPC ruby library to be used in a 'require' statement
  - lib/grpc/core: the pure Ruby implementation of the gRPC core surface
    (channels, calls, servers, credentials) on top of an HTTP/2 stack
  - lib/grpc/core/http2/kantan: vendored copy of [kantan][], a pure Ruby
    HTTP/2 implementation, namespaced under `GRPC::Core::Http2`
  - see [IMPLEMENTATION.md](IMPLEMENTATION.md) for how the core is put
    together, what is verified, and what is not done yet
- spec: Rspec unittests
- bin: example gRPC clients and servers, e.g,

  ```ruby
  stub = Math::Math::Stub.new('my.test.math.server.com:8080', :this_channel_is_insecure)
  req = Math::DivArgs.new(dividend: 7, divisor: 3)
  GRPC.logger.info("div(7/3): req=#{req.inspect}")
  resp = stub.div(req)
  GRPC.logger.info("Answer: #{resp.inspect}")
  ```

[kantan]: https://github.com/tenderlove/kantan
[rubydoc]: http://www.rubydoc.info/gems/grpc
[grpc.io]: https://grpc.io/docs/languages/ruby/quickstart
[Debian jessie-backports]:http://backports.debian.org/Instructions/
