# based on <github.com/jnicklas/capybara/blob/ab62b27/lib/capybara/server.rb>
require 'net/http'
require 'timeout'

module Faraday
  # Internal: Starts a server for a Sinatra/Rack app in background,
  # automatically assigning it an available port, blocking until it's ready to
  # process requests. This is an abstract class; you should use one of its
  # concrete implementations: LocalServerThreaded or LocalServerForked.
  #
  # Examples
  #
  #   server = LocalServerThreaded.start_sinatra do
  #     get('/') { 'hello world' }
  #   end
  #
  #   server.port
  #   server.stop
  class LocalServer
    class Identify < Struct.new(:app)
      def call(env)
        if env["PATH_INFO"] == "/__identify__"
          [200, {}, [app.object_id.to_s]]
        else
          app.call(env)
        end
      end
    end

    def self.ports
      @ports ||= {}
    end

    def self.run_handler(app, port, &block)
      begin
        require 'rack/handler/thin'
        Thin::Logging.silent = true
        Rack::Handler::Thin.run(app, :Port => port, &block)
      rescue LoadError
        require 'rack/handler/webrick'
        Rack::Handler::WEBrick.run(app, :Port => port, :AccessLog => [], :Logger => WEBrick::Log::new(nil, 0), &block)
      end
    end

    def self.start_sinatra(klass = nil, &block)
      unless klass
        require 'sinatra/base'
        klass = Class.new(Sinatra::Base)
        klass.set :environment, :test
        klass.disable :protection
        klass.class_eval(&block)
      end

      new(klass.new).start
    end

    attr_reader :app, :host, :port
    attr_accessor :server

    def initialize(app, host = '127.0.0.1')
      @app = app
      @host = host
      @server = nil
    end

    def responsive?
      res = Net::HTTP.start(host, port) { |http|
        http.open_timeout = http.read_timeout = 0.05
        http.get('/__identify__')
      }

      res.is_a?(Net::HTTPSuccess) and res.body == app.object_id.to_s
    rescue Errno::ECONNREFUSED, Errno::EBADF
      return false
    end

    def start
      @port = self.class.ports[app.object_id]

      if not @port or not responsive?
        @port = find_available_port
        self.class.ports[app.object_id] = @port

        in_background do
          self.class.run_handler(Identify.new(app), @port) { |server|
            self.server = server
          }
        end

        Timeout.timeout(10) { wait_until_responsive }
      end
    rescue TimeoutError
      raise "Rack application timed out during boot"
    else
      self
    end

    def stop
      server.respond_to?(:stop!) ? server.stop! : server.stop
    end

  private

    def find_available_port
      server = TCPServer.new('127.0.0.1', 0)
      server.addr[1]
    ensure
      server.close if server
    end
  end

  # Public: A type of LocalServer implemented using threads. This works very
  # well and is fast, but cannot be used in combination with Patron.
  class LocalServerThreaded < LocalServer
    def initialize(*)
      super
      @server_thread = nil
    end

    def responsive?
      return false if @server_thread && @server_thread.join(0)
      super
    end

    # arity compatibility with LocalServerForked#stop
    def stop(_ = nil)
      super
      @server_thread.join
      @server_thread = nil
    end

  private

    def in_background
      @server_thread = Thread.new { yield }
    end

    def wait_until_responsive
      @server_thread.join(0.1) until responsive?
    end
  end

  # Public: A type of LocalServer that spins up in a separate process. This is
  # somewhat slower than threads, especially when waiting synchronously for
  # server shutdown (anybody knows why?), but works with Patron.
  class LocalServerForked < LocalServer
    def initialize(*)
      super
      @pid = nil
    end

    alias shutdown stop
    def stop(async = false)
      Process.kill('INT', @pid)
      unless async
        begin Process.wait(@pid)
        rescue Errno::ECHILD
          warn "warning: got #{$!.class} while waiting for pid #{@pid}"
        end
      end
      @pid = nil
    end

  private

    def in_background
      @pid = Process.fork do
        trap(:INT) { self.shutdown }
        yield
        exit
      end
    end

    def wait_until_responsive
      sleep 0.05 until responsive?
    end
  end
end
