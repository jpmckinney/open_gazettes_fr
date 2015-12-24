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
    /\A(RCS-A)_BX(A)(\d{8})\.taz\z/,
    /\A(PCL)_BX(A)(\d{8})\.taz\z/,
    /\A(DIV)(A)(\d{12})\.taz\z/,
    /\A(RCS-B)_BX(B)(\d{8})\.taz\z/,
    /\A(BILAN)_BX(C)(\d{8})\.taz\z/,
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

  MONTH_NAMES = {
    'janvier' => 'January',
    'février' => 'February',
    'mars' => 'March',
    'avril' => 'April',
    'mai' => 'May',
    'juin' => 'June',
    'juillet' => 'July',
    'août' => 'August',
    'septembre' => 'September',
    'octobre' => 'October',
    'novembre' => 'November',
    'décembre' => 'December',
  }.freeze

  MONTH_NAMES_RE = Regexp.new(MONTH_NAMES.keys.join('|')).freeze

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
      publication = "BODACC #{match[2]}"
      issue_number_from_filename = match[3]

      if Env.development? && (ENV['from_issue_number'] && issue_number_from_filename < ENV['from_issue_number'] || ENV['format'] && format != ENV['format'])
        return
      elsif format != 'RCS-A'
        # TODO Add support for other formats.
        debug("Skipping #{basename}")
        return
      end

      Gem::Package::TarReader.new(uncompress(file.path)).each do |entry|
        document = Nokogiri::XML(entry.read.force_encoding('iso-8859-1').encode('utf-8'), nil, 'utf-8')

        issue_number = document.at_xpath('//parution').text
        assert("expected #{issue_number_from_filename}, got #{issue_number}"){issue_number == issue_number_from_filename}

        date_published = document.at_xpath('//dateParution').text
        date_published = case date_published
        when %r{/\d{4}\z}
          Date.strptime(date_published, '%d/%m/%Y')
        when %r{\A\d{4}/}
          Date.strptime(date_published, '%Y/%m/%d')
        else
          Date.strptime(date_published, '%Y-%m-%d')
        end
        date_published = date_published.strftime('%Y-%m-%d')

        # TODO If we want to validate the XML, we need to resolve this error,
        # which may be related to the `ISO_Currency_Code_2001.xsd`.
        # "simple type 'Devise_Type', attribute 'base': The QName value
        # '{urn:un:unece:uncefact:codelist:standard:5:4217:2001}CurrencyCodeContentType'
        # does not resolve to a(n) simple type definition."

        # _, version = VERSIONS.find do |start_date,_|
        #   start_date < date_published
        # end
        # schema = SCHEMAS.fetch(format) % version.fetch(format)
        # @schemas[schema] ||= Nokogiri::XML::Schema(File.read(File.expand_path(File.join('docs', 'xsd', schema), Dir.pwd)))
        # @schemas[schema].validate(document).each do |error|
        #   warn(error.message)
        # end

        path = format == 'PCL' ? 'annonces/annonce' : 'listeAvis/avis'
        document.xpath("//#{path}").each do |node|
          notice_type = node.at_xpath('./typeAnnonce/*').name # "annonce", "rectificatif", "annulation"
          uid = node.at_xpath('./nojo').text
          identifier = Integer(node.at_xpath('./numeroAnnonce').text)
          department_number = node.at_xpath('./numeroDepartement').text
          tribunal = node.at_xpath('./tribunal').text.gsub("\n", " ")

=begin
          personnes
          etablissement
          precedentProprietairePM
          precedentProprietairePP
          precedentExploitantPM
          precedentExploitantPP
          # The two PM and two PP are formatted the same
=end

          # <parutionAvisPrecedent>
          if node.at_xpath('./parutionAvisPrecedent')
            if !['rectificatif', 'annulation'].include?(notice_type)
              warn("unexpected parutionAvisPrecedent for typeAnnonce of #{notice_type}")
            end

            prior_publication = xpath(node, 'parutionAvisPrecedent/nomPublication', required: true) # e.g. "BODACC A"
            prior_issue_number = xpath(node, 'parutionAvisPrecedent/numeroParution', required: true)
            prior_date_published = xpath(node, 'parutionAvisPrecedent/dateParution', required: true, format: :date, pattern: '%e %B %Y')
            prior_identifier = xpath(node, 'parutionAvisPrecedent/numeroAnnonce', required: true, type: :integer)
          end

          # <acte>
          subnode = node.at_xpath('./acte/*')
          act_type = subnode.name # "creation", "immatriculation", "vente"
          classification = xpath(subnode, "categorie#{act_type.capitalize}", required: act_type == 'creation') # required by schema, but sometimes missing
          date_registered = xpath(subnode, 'dateImmatriculation', format: :date)
          start_date = xpath(subnode, 'dateCommencementActivite', format: :date)
          description = xpath(subnode, 'descriptif')

          if ['immatriculation', 'vente'].include?(act_type)
            effective_date = xpath(subnode, 'dateEffet', format: :date, pattern: '%e %B %Y')
          end

          if act_type == 'vente'
            if subnode.at_xpath('./journal')
              journal_title = xpath(subnode, 'journal/titre', required: true)
              journal_date = xpath(subnode, 'journal/date', required: true)
            end

            opposition = xpath(subnode, 'opposition')
            debt_declaration = xpath(subnode, 'declarationCreance')
          end
        end

        # TODO
        # finish parsing into variables
        # combine the variables into a hash and output
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

  def xpath(parent, path, options = {})
    node = parent.at_xpath("./#{path}")
    if node
      value = node.text
      case options[:type]
      when :integer
        begin
          Integer(value)
        rescue ArgumentError => e
          error("#{e} in:\n#{parent.to_s}")
        end
      else
        case options[:format]
        when :date
          pattern = options[:pattern] || '%Y-%m-%d'
          if pattern['%B']
            value = value.gsub(MONTH_NAMES_RE){|match| MONTH_NAMES.fetch(match)}.sub(/\A1er\b/, '1').gsub(/\p{Space}/, ' ')
          end
          begin
            Date.strptime(value, pattern).strftime('%Y-%m-%d')
          rescue ArgumentError => e
            error("#{e}: #{value}")
          end
        else
          value
        end
      end
    elsif options[:required]
      warn("expected #{path} in:\n#{parent.parent.to_s}")
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
