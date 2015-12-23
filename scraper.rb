# coding: utf-8

require 'net/ftp'
require 'forwardable'
require 'logger'
require 'rubygems/package'
require 'tempfile'

require 'nokogiri'
require 'turbotlib'

# Architecture
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
        if defined?(FaradayMiddleware)
          connection.response :caching do
            ActiveSupport::Cache::FileStore.new(cache_dir, expires_in: expires_in)
          end
        end
        connection.adapter Faraday.default_adapter
      end
    end
  end

  class Processor
    extend Forwardable

    attr_reader :client

    def_delegators :@logger, :debug, :info, :warn, :error, :fatal

    def initialize(level, logdev)
      @logger = Logger.new('turbot', level, logdev)
    end

    def assert(message)
      raise message unless yield
    end
  end
end

# Scraper

class FR_BODACC < Framework::Processor
  class FTP < Net::FTP
    extend Forwardable

    def_delegators :@logger, :debug, :info, :warn, :error, :fatal

    attr_accessor :logger

    # Downloads a remote file.
    #
    # @param [String] remotefile the name of the remote file
    # @return [File,Tempfile] a local file with the remote file's contents
    def download(remotefile)
      info("get #{remotefile}")

      path = File.expand_path(File.join('data', 'echanges.dila.gouv.fr', pwd, remotefile), Dir.pwd)

      if Env.development? && File.exist?(path)
        File.open(path)
      else
        if Env.development?
          File.open(path, 'w') do |f|
            getbinaryfile(remotefile, f.path)
            f
          end
        else
          Tempfile.open([remotefile, '.Z']) do |f|
            getbinaryfile(remotefile, f.path)
            f
          end
        end
      end
    end
  end

  class DataFile
    attr_reader :name

    # @param [String] name the filename
    # @param arg an argument needed to write the tempfile
    def initialize(name, arg)
      @name = name
      @arg = arg
    end
  end

  class TaredTazFile < DataFile
    def path
      Tempfile.open([name, '.Z']){|f|
        f.binmode
        f.write(@arg.read)
        f
      }.path
    end
  end

  class RemoteTazFile < DataFile
    def path
      @arg.download(name).path
    end
  end

  def scrape
    FTP.open('echanges.dila.gouv.fr') do |ftp|
      ftp.logger = @logger
      ftp.login

      ftp.chdir('BODACC')
      ftp.nlst.each do |remotefile|
        # Previous years are archived as `.tar` files.
        if File.extname(remotefile) == '.tar'
          Gem::Package::TarReader.new(ftp.download(remotefile)).each do |entry|
            if entry.file?
              parse(TaredTazFile.new(entry.full_name, entry), remotefile)
            end
          end

        # The present year contains individual `.taz` files.
        elsif remotefile[/\A\d{4}\z/]
          ftp.chdir(remotefile)
          ftp.nlst.each do |name|
            parse(RemoteTazFile.new(name, ftp), remotefile)
          end
          ftp.chdir('..')

        elsif remotefile != 'DOCUMENTATIONS'
          warn("unexpected file BODACC/#{remotefile}")
        end
      end
    end
  end

  def parse(file, directory)
    if File.extname(file.name) == '.taz'
      # Ruby has no LZW decompression gems or standard libraries.
      # `PDF::Reader::LZW.decode` exists, but fails.
      # We can't stream to `Gem::Package::TarReader` with `IO.popen` or
      # similar because it causes "Errno::ESPIPE: Illegal seek".
      io = uncompress(file.path)
      Gem::Package::TarReader.new(io).each do |entry|
        Nokogiri::XML(entry.read)

        # TODO
        # Parse according to schema
        # Use Nori to transform into JSON for other_attributes
      end
    else
      warn("unexpected file extension #{file.name} in BODACC/#{directory}")
    end
  end

  def uncompress(oldpath)
    # The `uncompress` command doesn't work unless the filename ends in ".Z".
    rename = File.extname(oldpath) != '.Z'
    begin
      if rename
        newpath = "#{oldpath}.Z"
        File.rename(oldpath, newpath)
        path = newpath
      else
        path = oldpath
      end
      StringIO.new(`uncompress -c #{path}`)
    ensure
      if rename
        File.rename(newpath, oldpath)
      end
    end
  end
end

# We can't use keyword arguments like in Pupa until Ruby 2.
args = if Env.development?
  [
    'INFO', # level
    STDOUT, # logdev
  ]
else
  [
    'WARN',
    STDERR,
  ]
end

FR_BODACC.new(*args).scrape
