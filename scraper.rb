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

  class BODACCFTP < Net::FTP
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
    BODACCFTP.open('echanges.dila.gouv.fr') do |ftp|
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

          options = {
            retrieved_at: now,
            source_url: "ftp://echanges.dila.gouv.fr#{ftp.pwd}/#{remotefile}",
          }
          Gem::Package::TarReader.new(ftp.download(remotefile)).each do |entry|
            if entry.file?
              parse(TaredTazFile.new(entry.full_name, entry), remotefile, options)
            end
          end

        # The present year contains individual `.taz` files.
        elsif remotefile[/\A\d{4}\z/]
          if Env.development? && ENV['year'] && remotefile != ENV['year']
            next
          end

          ftp.chdir(remotefile)
          ftp.nlst.each do |name|
            # I can't find a media type for LZW-compressed `.taz` files.
            url = "ftp://echanges.dila.gouv.fr#{ftp.pwd}/#{name}"
            parse(RemoteTazFile.new(name, ftp), remotefile, {
              url: url,
              source_url: url,
            })
          end
          ftp.chdir('..')

        elsif remotefile != 'DOCUMENTATIONS'
          warn("unexpected file BODACC/#{remotefile}")
        end
      end
    end
  end

  # @param [DataFile] the file to parse
  # @param [String] the file's directory
  # @param [Hash] options
  # @option options [String] :url the issue URL
  # @option options [String] :source_url the source URL
  # @option options [String] :retrieved_at the time of retrieval
  def parse(file, directory, options)
    if File.extname(file.name) == '.taz'
      basename = File.basename(file.name)

      match = nil
      FILENAME_PATTERNS.find do |pattern|
        match = basename.match(pattern)
      end
      assert("unrecognized filename pattern #{basename}"){match}

      format = match[1]
      edition_id = match[2]
      issue_number_from_filename = match[3]

      if Env.development? && (ENV['from_issue_number'] && issue_number_from_filename < ENV['from_issue_number'] || ENV['format'] && format != ENV['format'])
        return
      elsif format != 'RCS-A'
        # TODO Add support for other formats.
        debug("Skipping #{basename}")
        return
      end

      retrieved_at = options[:retrieved_at] || now
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

        default_record = {
          issue: {
            publication: {
              publisher: {
                name: "Direction de l'information légale et administrative",
                url: 'http://www.dila.premier-ministre.gouv.fr/',
              },
              jurisdiction_code: 'fr',
              title: 'Bulletin officiel des annonces civiles et commerciales',
              url: 'http://www.bodacc.fr/',
            },
            identifier: issue_number,
            edition_id: edition_id,
            url: options[:url],
          },
          date_published: date_published,
          source_url: options[:source_url],
          sample_date: retrieved_at,
          retrieved_at: retrieved_at,
          confidence: 'HIGH',
        }

        path = format == 'PCL' ? 'annonces/annonce' : 'listeAvis/avis'
        document.xpath("//#{path}").each do |node|
          notice_type = one(node, 'typeAnnonce/*').name # "annonce", "rectificatif", "annulation"
          uid = value(node, 'nojo')
          identifier = value(node, 'numeroAnnonce', format: :integer)
          department_number = value(node, 'numeroDepartement')
          tribunal = value(node, 'tribunal').gsub("\n", " ")

          node.xpath('/personnes/personne').each do |personne|
            subnode = one(personne, 'personneMorale')
            person = moral_person(subnode)
            subnode = one(personne, 'personnePhysique')
            if person
              warn("expected only one of personneMorale or personnePhysique")
            else
              person = physical_person(subnode)
            end

            subnode = one(personne, 'capital')
            if subnode
              amount_value = value(subnode, 'montantCapital')
              currency = value(subnode, 'devise')
              amount = value(subnode, 'capitalVariable')
            end

            subnode = one(personne, 'adresse')
            if subnode
              address = if subnode.at_xpath('./france')
                france_address(subnode, 'france')
              elsif subnode.at_xpath('./etranger')
                {
                  address: value(subnode, 'etranger/adresse'),
                  country_name: value(subnode, 'etranger/pays'),
                }
              end
            end
          end

          subnodes = node.xpath('./etablissement')
          establishment = subnodes.map do |subnode|
            {
              origin: value(subnode, 'origineFonds'),
              establishment_type: value(subnode, 'qualiteEtablissement'),
              activity: value(subnode, 'activite'),
              sign: value(subnode, 'enseigne'),
              address: france_address(subnode, 'adresse'),
            }
          end

          # <precedentProprietairePM> <precedentProprietairePP>
          subnodes = node.xpath('./precedentProprietairePM')
          previous_owners = subnodes.map do |subnode|
            moral_person(subnode)
          end
          subnodes = node.xpath('./precedentProprietairePP')
          previous_owners += subnodes.map do |subnode|
            physical_person(subnode)
          end

          # <precedentExploitantPM> <precedentExploitantPP>
          subnodes = node.xpath('./precedentExploitantPM')
          previous_operators = subnodes.map do |subnode|
            moral_person(subnode)
          end
          subnodes = node.xpath('./precedentExploitantPP')
          previous_operators += subnodes.map do |subnode|
            physical_person(subnode)
          end

          # <parutionAvisPrecedent>
          subnode = one(node, 'parutionAvisPrecedent')
          if subnode
            prior_publication = value(subnode, 'nomPublication', required: true, enum: ['BODACC A', 'BODACC B', 'BODACC C'])
            prior_issue_number = value(subnode, 'numeroParution', required: true)
            prior_date_published = value(subnode, 'dateParution', required: true, format: :date, pattern: '%e %B %Y')
            prior_identifier = value(subnode, 'numeroAnnonce', required: true, type: :integer)
          end

          # <acte>
          subnode = one(node, 'acte/*')
          act_type = subnode.name # "creation", "immatriculation", "vente"
          classification = value(subnode, "categorie#{act_type.capitalize}", required: act_type == 'creation') # required by schema, but sometimes missing
          date_registered = value(subnode, 'dateImmatriculation', format: :date)
          start_date = value(subnode, 'dateCommencementActivite', format: :date)
          description = value(subnode, 'descriptif')

          if ['immatriculation', 'vente'].include?(act_type)
            effective_date = value(subnode, 'dateEffet', format: :date, pattern: '%e %B %Y')
          end

          if act_type == 'vente'
            if subnode.at_xpath('./journal')
              journal_title = value(subnode, 'journal/titre', required: true)
              journal_date = value(subnode, 'journal/date', required: true, format: :date)
            end

            opposition = value(subnode, 'opposition')
            debt_declaration = value(subnode, 'declarationCreance')
          end
        end

        # TODO
        # combine the variables into a hash, exclude nil values, and output
      end
    else
      warn("unexpected file extension #{file.name} in BODACC/#{directory}")
    end
  end

  ### Helpers

  # @return [String] the present UTC time in ISO 8601 format
  def now
    Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  end

  # @param [String] a file path to a compressed file
  # @return [StringIO] an IO of the uncompressed file
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

  # @param [Nokogiri::XML::Element] parent a parent node
  # @param [path] path an XPath path
  # @return [Nokogiri::XML::Element] a child node
  def one(parent, path)
    nodes = parent.xpath("./#{path}")
    if nodes.any?
      if nodes.size > 1
        warn("expected 0..1 #{path} in #{parent.name}, got #{nodes.size}")
      end
      nodes[0]
    end
  end

  # @param [Nokogiri::XML::Element] parent a parent node
  # @param [path] path an XPath path
  # @param [Hash] options validation options
  # @return [String,Integer] a value
  def value(parent, path, options = {})
    node = one(parent, path)
    if node
      value = node.text.strip

      if options[:type] == :integer
        begin
          Integer(value)
        rescue ArgumentError => e
          error("#{e} in:\n#{parent.to_s}")
        end

      elsif options[:format] == :date
        pattern = options[:pattern] || '%Y-%m-%d'
        if pattern['%B']
          value = value.gsub(MONTH_NAMES_RE){|match| MONTH_NAMES.fetch(match)}.sub(/\A1er\b/, '1').gsub(/\p{Space}/, ' ')
        end
        begin
          Date.strptime(value, pattern).strftime('%Y-%m-%d')
        rescue ArgumentError => e
          error("#{e}: #{value}")
        end

      elsif options[:pattern]
        value.match(options[:pattern])[0]

      else
        if options[:enum] && !options[:enum].include?(value)
          warn("expected #{value.inspect} in #{options[:enum].inspect}")
        end
        value
      end

    elsif options[:required]
      warn("expected #{path} in:\n#{parent.parent.to_s}")
    end
  end

  ### Helpers for generic XML sections

  # @param [Nokogiri::XML::Element] parent a parent node
  # @return [Hash] the values of the moral person
  def moral_person(parent)
    if parent
      {
        type: 'Moral person',
        name: value(parent, 'denomination', required: true),
        registration: registration_number(parent),
        # <personneMorale> only
        company_type: value(parent, 'formeJuridique'),
        alternative_names: [{
          company_name: value(parent, 'nomCommercial'),
          type: 'trading',
        }, {
          company_name: value(parent, 'sigle'),
          type: 'abbreviation',
        }],
        directors: value(parent, 'administration'), # TODO parse
      }
    end
  end

  # @param [Nokogiri::XML::Element] parent a parent node
  # @return [Hash] the values of the physical person
  def physical_person(parent)
    if parent
      {
        type: 'Physical person',
        family_name: value(parent, 'nom', required: true),
        given_name: value(parent, 'prenom'),
        customary_name: value(parent, 'nomUsage'),
        registration: registration_number(parent),
        # <precedentProprietairePP> and <precedentExploitantPP> only
        nature: value(parent, 'nature'),
        # <personnePhysique> only
        alternative_names: [{
          name: value(parent, 'pseudonyme'),
        }, {
          name: value(parent, 'nomCommercial'),
        }],
        nationality: value(parent, 'nationalite'),
      }
    end
  end

  # @param [Nokogiri::XML::Element] parent a parent node
  # @return [Hash] the values of the registration
  def registration_number(parent)
    node = one(parent, 'numeroImmatriculation')
    if node
      {
        registered: true,
        number: value(node, 'numeroIdentification', required: true, pattern: /\A\d{3} \d{3} \d{3}\z/),
        rcs: value(node, 'codeRCS', required: true, enum: ['RCS']),
        clerk: value(node, 'nomGreffeImmat', required: true),
      }
    elsif parent.at_xpath('./nonInscrit')
      {
        registered: !value(parent, 'nonInscrit', enum: ['RCS non inscrit.']),
      }
    end
  end

  # @param [Nokogiri::XML::Element] parent a parent node
  # @param [path] path an XPath path
  # @return [Hash] the values of the address
  def france_address(parent, path)
    node = one(parent, path)
    if node
      # @see AddressRepresentation and LocatorDesignatorTypeValue in http://inspire.ec.europa.eu/documents/Data_Specifications/INSPIRE_DataSpecification_AD_v3.0.1.pdf
      {
        locator_designator_address_number: value(node, 'numeroVoie', format: :integer),
        thoroughfare_type: value(node, 'typeVoie'),
        thoroughfare_name: value(node, 'nomVoie'),
        locator_designator_building_identifier: value(node, 'complGeographique'),
        locator_designator_postal_delivery_identifier: value(node, 'BP'),
        address_area: value(node, 'localite'),
        post_code: value(node, 'codePostal', required: true, format: :integer),
        admin_unit: value(node, 'ville', required: true),
        country_name: 'France',
      }
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
