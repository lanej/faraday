unless ENV['CI']
  begin
    require 'simplecov'
    SimpleCov.start do
      add_filter 'test'
    end
  rescue LoadError
  end
end

at_exit do
  # this hook needs to be installed before loading "test/unit"
  Faraday::TestCase.stop_live_server
end

require 'test/unit'
require 'webmock/test_unit'
WebMock.disable_net_connect! :allow_localhost => true

if ENV['LEFTRIGHT']
  begin
    require 'leftright'
  rescue LoadError
    puts "Run `gem install leftright` to install leftright."
  end
end

require File.expand_path('../../lib/faraday', __FILE__)

begin
  require 'ruby-debug'
rescue LoadError
  # ignore
else
  Debugger.start
end

require 'stringio'
require 'uri'

module Faraday
  module LiveServerConfig
    # Configure live server. Possible values are:
    # - an HTTP URL
    # - "auto"
    # - non-empty string
    def live_server_config=(config)
      @@live_server_config = config
    end

    def live_server?
      defined? @@live_server_config and !@@live_server_config.empty?
    end

    # Returns an object that responds to `host` and `port`.
    def live_server
      return @@live_server if defined? @@live_server
      @@live_server = init_live_server
    end

    # Asynchronously stop the server. Important if it's running in subprocess
    def stop_live_server
      if defined? @@live_server and @@live_server.respond_to? :stop
        @@live_server.stop(:no_wait)
      end
    end

    private
    def init_live_server
      case @@live_server_config
      when /^http/
        URI(@@live_server_config)
      when 'auto'
        require File.expand_path('../local_server.rb', __FILE__)
        require File.expand_path('../live_server.rb', __FILE__)
        LocalServerForked.start_sinatra LiveServer
      when /./
        URI('http://127.0.0.1:4567')
      end
    end
  end

  class TestCase < Test::Unit::TestCase
    extend LiveServerConfig
    self.live_server_config = ENV['LIVE']

    def test_default
      assert true
    end unless defined? ::MiniTest

    def capture_warnings
      old, $stderr = $stderr, StringIO.new
      begin
        yield
        $stderr.string
      ensure
        $stderr = old
      end
    end
  end
end
