# coding: utf-8

require_relative 'framework'

require 'net/ftp'
require 'rubygems/package'
require 'tempfile'

class FR_BODACC < Framework::Processor
  # @see "4. REPARTITION DES ANNONCES BODACC"
  FILENAME_PATTERNS = [
    /\A(RCS-A)_BX(A)(\d{8})\.taz\z/,
    /\A(PCL)_BX(A)(\d{8})\.taz\z/,
    /\A(DIV)(A)(\d{12})\.taz\z/,
    /\A(RCS-B)_BX(B)(\d{8})\.taz\z/,
    /\A(BILAN)_BX(C)(\d{8})\.taz\z/,
  ].freeze

  class FR_BODACC_FTP < Net::FTP
    extend Forwardable

    attr_accessor :logger

    def_delegators :@logger, :debug, :info, :warn, :error, :fatal

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
    # @return [String] the filename
    attr_reader :name

    # @param [String] name the filename
    # @param arg an argument needed to write the tempfile
    def initialize(name, arg)
      @name = name
      @arg = arg
    end

    # Downloads a file and returns its path.
    #
    # @return [String] the path to the file
    def path
      raise NotImplementedError
    end
  end

  class TaredTazFile < DataFile
    # @note `@arg` is a `Gem::Package::TarReader::Entry`.
    def path
      Tempfile.open([name.gsub(File::SEPARATOR, '-'), '.Z']){|f|
        f.binmode
        f.write(@arg.read)
        f
      }.path
    end
  end

  class RemoteTazFile < DataFile
    # @note `@arg` is a `FR_BODACC_FTP`.
    def path
      @arg.download(name).path
    end
  end

  def scrape
    FR_BODACC_FTP.open('echanges.dila.gouv.fr') do |ftp|
      ftp.logger = @logger
      ftp.passive = true

      info('login')
      ftp.login

      info('chdir BODACC')
      ftp.chdir('BODACC')

      info('nlst')
      ftp.nlst.each do |remotefile|
        # Previous years are archived as `.tar` files.
        if File.extname(remotefile) == '.tar'
          year = remotefile.match(/\ABODACC_(\d{4})\.tar\z/)[1]

          if Env.development? && ENV['year'] && year != ENV['year']
            next
          elsif year < '2012'
            # TODO Add support for files prior to 2011-12-07. First need to
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

          info("chdir #{remotefile}")
          ftp.chdir(remotefile)

          info('nlst')
          ftp.nlst.each do |name|
            # NOTE I can't find a media type for LZW-compressed `.taz` files,
            # which could be added as a property of the issue.
            url = "ftp://echanges.dila.gouv.fr#{ftp.pwd}/#{name}"
            parse(RemoteTazFile.new(name, ftp), remotefile, {
              issue_url: url,
              source_url: url,
            })
          end

          info('chdir ..')
          ftp.chdir('..')

        elsif remotefile != 'DOCUMENTATIONS'
          warn("unexpected file BODACC/#{remotefile}")
        end
      end
    end
  end

  # Outputs an issue as JSON.
  #
  # @param [DataFile] the file to parse
  # @param [String] the file's directory
  # @param [Hash] options
  # @option options [String] :issue_url the issue URL
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
      issue_number = match[3]

      if Env.development? && (ENV['format'] && format != ENV['format'] || ENV['from_issue_number'] && issue_number < ENV['from_issue_number'] || ENV['to_issue_number'] && issue_number > ENV['to_issue_number'])
        return
      end

      # If given a `RemoteTazFile`, retrieval is now.
      retrieved_at = options[:retrieved_at] || now
      Gem::Package::TarReader.new(uncompress(file.path)).each do |entry|
        xml = entry.read

        puts JSON.dump({
          identifier: issue_number,
          edition_id: edition_id,
          url: options[:issue_url],
          other_attributes: {
            format: format,
            data: xml.force_encoding('iso-8859-1').encode('utf-8'), # the order of XML elements matters for PCL only
          },
          default_attributes: {
            source_url: options[:source_url],
            retrieved_at: retrieved_at,
          },
          # Make primary-data-schema.json happy.
          source_url: options[:source_url],
          sample_date: retrieved_at,
        })
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

  # Uncompresses a file.
  #
  # @param [String] a file path to a compressed file
  # @return [StringIO] the uncompressed file
  def uncompress(oldpath)
    # Ruby has no gem or library for LZW decompression; `PDF::Reader::LZW.decode`
    # exists, but fails. The `uncompress` command works only if the extension is ".Z".
    perform_rename = File.extname(oldpath) != '.Z'
    begin
      if perform_rename
        newpath = "#{oldpath}.Z"
        File.rename(oldpath, newpath)
        path = newpath
      else
        path = oldpath
      end
      # We can't stream to `Gem::Package::TarReader` with `IO.popen` or similar
      # because it causes "Errno::ESPIPE: Illegal seek".
      StringIO.new(`uncompress -c #{path}`)
    ensure
      if perform_rename
        File.rename(newpath, oldpath)
      end
    end
  end
end

# We can't use keyword arguments like in Pupa until Ruby 2.
args = if Env.development?
  [
    '.',
    '.',
    0,
    'INFO', # level
    STDERR, # logdev
  ]
else
  [
    '.',
    '.',
    0,
    'WARN',
    STDERR,
  ]
end

FR_BODACC.new(*args).scrape
