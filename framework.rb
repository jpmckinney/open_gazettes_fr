require 'fileutils'
require 'forwardable'
require 'logger'
require 'net/ftp'

require 'turbotlib'
require 'faraday'

begin
  require 'faraday_middleware'
  require 'active_support/cache'
rescue LoadError
  # Production doesn't need caching.
end

# @see https://github.com/jpmckinney/pupa-ruby

module Env
  def self.development?
    ENV['TURBOT_ENV'] == 'development'
  end
end

module Framework
  class Logger
    def self.new(progname, level, logdev)
      logger = ::Logger.new(logdev)
      logger.level = ::Logger.const_get(level)
      logger.progname = progname
      logger.formatter = proc do |severity, datetime, progname, msg|
        "#{datetime.strftime('%T')} #{severity} #{progname}: #{msg}\n"
      end
      logger
    end
  end

  class Client
    def self.new(cache_dir, expires_in, level, logdev)
      Faraday.new do |connection|
        connection.request :url_encoded
        connection.use Faraday::Response::Logger, Logger.new('faraday', level, logdev)
        if defined?(FaradayMiddleware) && cache_dir
          connection.response :caching do
            ActiveSupport::Cache::FileStore.new(cache_dir, expires_in: expires_in)
          end
        end
        connection.adapter Faraday.default_adapter
      end
    end
  end

  class FTPDelegator < SimpleDelegator
    # echanges.dila.gouv.fr sometimes returns a local IP (192.168.30.9) for the
    # host in `#makepasv`. We can store the first host received (which we assume
    # to be good), and return it every time. However, even with a good IP, the
    # next command times out. So, we instead retry the entire command with a new
    # client.
    def method_missing(m, *args, &block)
      begin
        super
      rescue Errno::ETIMEDOUT, Net::ReadTimeout => e
        @delegate_sd_obj.error(e.message)
        @delegate_sd_obj.close
        __setobj__(FTP.new(*@delegate_sd_obj.initialize_arguments))
        retry
      end
    end
  end

  class FTP < Net::FTP
    extend Forwardable

    attr_accessor :logger
    attr_accessor :root_path
    attr_reader :initialize_arguments

    def_delegators :@logger, :debug, :info, :warn, :error, :fatal

    def initialize(host = nil, user = nil, passwd = nil, acct = nil)
      super
      # Store so we can recreate an FTP client.
      @initialize_arguments = [host, user, passwd, acct]
    end

    # Downloads a remote file.
    #
    # @param [String] remotefile the name of the remote file
    # @return [File] a local file with the remote file's contents
    def download(remotefile)
      info("get #{remotefile}")

      path = File.join(root_path, pwd, remotefile)

      if Env.development? && File.exist?(path)
        File.open(path)
      else
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, 'w') do |f|
          getbinaryfile(remotefile, f.path)
        end
        File.open(path)
      end
    end
  end

  class Processor
    extend Forwardable

    attr_reader :client

    def_delegators :@logger, :debug, :info, :warn, :error, :fatal

    def initialize(output_dir, cache_dir, expires_in, level, logdev)
      @logger = Logger.new('turbot', level, logdev)
      @client = Client.new(cache_dir, expires_in, level, logdev)

      @output_dir = output_dir
      FileUtils.mkdir_p(@output_dir)
    end

    def get(url)
      client.get(url).body
    end

    def assert(message)
      error(message) unless yield
    end

    # @return [String] the present UTC time in ISO 8601 format
    def now
      Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    end
  end
end
