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
  # @see "4. REPARTITION DES ANNONCES BODACC"
  FILENAME_PATTERNS = [
    /\A(RCS-A)_BX(A)(\d{4})(\d{4})\.taz\z/,
    /\A(PCL)_BX(A)(\d{4})(\d{4})\.taz\z/,
    /\A(DIV)(A)(\d{8})(\d{4})\.taz\z/,
    /\A(RCS-B)_BX(B)(\d{4})(\d{4})\.taz\z/,
    /\A(BILAN)_BX(C)(\d{4})(\d{4})\.taz\z/,
  ].freeze

  SCHEMAS = {
    'RCS-A' => 'RCI_V%0d.xsd',
    'PCL' => 'PCL_V%0d.xsd',
    'DIV' => 'Divers_V%02d.xsd',
    'RCS-B' => 'RCM_V%02d.xsd',
    'BILAN' => 'Bilan_V%02d.xsd',
  }.freeze

  VERSIONS = {
    # Must be in reverse chronological order.
    '2015-02-16' => {
      'RCS-A' => 10,
      'PCL' => 13,
      'DIV' => 1,
      'RCS-B' => 11,
      'BILAN' => 6,
    },
    '2014-04-01' => {
      'RCS-A' => 10,
      'PCL' => 12,
      'DIV' => 1,
      'RCS-B' => 11,
      'BILAN' => 6,
    },
    '2011-12-07' => {
      'RCS-A' => 10,
      'PCL' => 11, # not in "DOCUMENTATIONS"
      'DIV' => 1,
      'RCS-B' => 11,
      'BILAN' => 3,
    },
  }.freeze

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
      Tempfile.open([name.gsub(File::SEPARATOR, '-'), '.Z']){|f|
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

  def initialize(*args)
    super
    @schemas = {}
  end

  def scrape
    FTP.open('echanges.dila.gouv.fr') do |ftp|
      ftp.logger = @logger
      ftp.login

      ftp.chdir('BODACC')
      ftp.nlst.each do |remotefile|
        # Previous years are archived as `.tar` files.
        if File.extname(remotefile) == '.tar'
          year = remotefile.match(/\ABODACC_(\d{4})\.tar\z/)[1]

          if Env.development? && ENV['year'] && year != ENV['year']
            next
          elsif year < '2012'
            # TODO Add support for files prior to 2011-12-07. Will need to
            # figure out which XSD are used between which dates.
            debug("Skipping #{remotefile}")
            next
          end

          Gem::Package::TarReader.new(ftp.download(remotefile)).each do |entry|
            if entry.file?
              parse(TaredTazFile.new(entry.full_name, entry), remotefile)
            end
          end

        # The present year contains individual `.taz` files.
        elsif remotefile[/\A\d{4}\z/]
          if Env.development? && ENV['year'] && remotefile != ENV['year']
            next
          end

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
      basename = File.basename(file.name)

      match = nil
      FILENAME_PATTERNS.find do |pattern|
        match = basename.match(pattern)
      end
      assert("unrecognized filename pattern #{basename}"){match}

      format = match[1]
      bodacc = match[2]
      number = Integer(match[4].sub(/\A0+/, ''))
      date = if match[3].size == 4
        Date.strptime(match[3], '%Y').strftime('%Y')
      else
        Date.strptime(match[3], '%Y%m%d').strftime('%Y-%m-%d')
      end

      if Env.development? && ENV['format'] && format != ENV['format']
        return
      elsif format != 'RCS-A'
        # TODO Add support for other formats.
        debug("Skipping #{basename}")
        return
      end

      schema = SCHEMAS.fetch(format)

      Gem::Package::TarReader.new(uncompress(file.path)).each do |entry|
        doc = Nokogiri::XML(entry.read)

        date_published = doc.at_xpath('//dateParution').text
        date_published = case date_published
        when %r{/\d{4}\z}
          Date.strptime(date_published, '%d/%m/%Y')
        when %r{\A\d{4}/}
          Date.strptime(date_published, '%Y/%m/%d')
        else
          Date.strptime(date_published, '%Y-%m-%d')
        end
        date_published = date_published.strftime('%Y-%m-%d')

        # TODO If we want to validate the XML, need to resolve this error:
        # "simple type 'Devise_Type', attribute 'base': The QName value
        # '{urn:un:unece:uncefact:codelist:standard:5:4217:2001}CurrencyCodeContentType'
        # does not resolve to a(n) simple type definition."

        # _, version = VERSIONS.find do |start_date,_|
        #   start_date < date_published
        # end
        # schema %= version.fetch(format)
        # @schemas[schema] ||= Nokogiri::XML::Schema(File.read(File.expand_path(File.join('docs', 'xsd', schema), Dir.pwd)))
        # @schemas[schema].validate(doc).each do |error|
        #   warn(error.message)
        # end

        # TODO
        # Parse according to schema by working throughs schema in Chrome
        # Use Nori to transform into JSON for other_attributes
      end
    else
      warn("unexpected file extension #{file.name} in BODACC/#{directory}")
    end
  end

  def uncompress(oldpath)
    # Ruby has no gem or library for LZW decompression; `PDF::Reader::LZW.decode`
    # exists, but fails. The `uncompress` command works only if the extension is ".Z".
    rename = File.extname(oldpath) != '.Z'
    begin
      if rename
        newpath = "#{oldpath}.Z"
        File.rename(oldpath, newpath)
        path = newpath
      else
        path = oldpath
      end
      # We can't stream to `Gem::Package::TarReader` with `IO.popen` or
      # similar because it causes "Errno::ESPIPE: Illegal seek".
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
