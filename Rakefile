require 'date'
require 'json'

require 'zip'

def docs
  @docs ||= File.expand_path('docs', Dir.pwd)
end

desc 'Configures the scraper'
task :configure do
  manifest_path = File.expand_path('manifest.json', Dir.pwd)
  manifest = JSON.load(File.read(manifest_path))

  manifest['bot_id'] = 'open_gazettes_fr_bodacc'
  manifest['title'] = 'OpenGazettes France BODACC'
  manifest['description'] = "An OpenGazettes scraper of France's BODACC."
  manifest['frequency'] = 'daily'

  if ENV['year']
    year = ENV['year']
    manifest['bot_id'] += "_#{year}"
    manifest['title'] += " #{year}"
    manifest['description'].sub!(/(?=\.\z)/, " in #{year}")
    manifest['frequency'] = 'oneoff'
  else
    year = Time.now.utc.year
  end

  File.open(manifest_path, 'w') do |f|
    f.write(JSON.pretty_generate(manifest) + "\n")
  end

  scraper_path = File.expand_path('scraper.rb', Dir.pwd)
  scraper = File.read(scraper_path)

  File.open(scraper_path, 'w') do |f|
    f.write(scraper.sub(/^  YEAR[^\n]+$/, "  YEAR = !Turbotlib.in_production? && ENV['year'] || '#{year}'"))
  end
end

desc 'Extracts XSD files'
task :xsd do
  def assert(message)
    raise message unless yield
  end

  zip_patterns = [
    /\AXSD_Bodacc_(Bilan)_Redif_ ?([\d_]{10})_(\d{3})\.zip\z/,
    /\AXSD_Bodacc_(Divers)_Redif_ ?([\d_]{10})_(\d{3})\.zip\z/,
    /\AXSD_Bodacc_(PCL)_Redif_ ?([\d_]{10})_(\d{3})\.zip\z/,
    /\AXSD_Bodacc_(RCI)_Redif_ ?([\d_]{10})_(\d{3})\.zip\z/,
    /\AXSD_Bodacc_(RCM)_Redif_ ?([\d_]{10})_(\d{3})\.zip\z/,
    /\AXSD_(ISO_CurrencyCode)_ ?([\d_]{10})_(\d{3})\.zip\z/,
  ]

  xsd_patterns = [
    /\ABodacc_(Bilan)_Redif_(?:[\d_]{10}_)?(V\d{2})\.xsd\z/,
    /\ABodacc_(Divers)_Redif_[\d_]{10}_(V\d{2})\.xsd\z/,
    /\ABodacc_(PCL)_Redif_(?:[\d_]{10}_)?(V\d{2})\.xsd\z/,
    /\ABodacc_(RCI)_Redif_[\d_]{10}_(V\d{2})\.xsd\z/,
    /\ABodacc_(RCM)_Redif_[\d_]{10}_(V\d{2})\.xsd\z/,
    /\A(ISO_CurrencyCode)_(\d{4})\.xsd\z/,
  ]

  cache = {}

  # TODO The XSD files in the pre-2011 directory are not copied.
  paths = Dir[File.expand_path(File.join('data', 'echanges.dila.gouv.fr', 'BODACC', 'DOCUMENTATIONS', '*_*', '*.zip'), Dir.pwd)].sort_by do |path|
    zip_name = File.basename(path)

    match = nil
    zip_patterns.find do |pattern|
      match = zip_name.match(pattern)
    end
    assert("unrecognized filename pattern #{zip_name}"){match}

    Date.strptime(match[2], '%Y_%m_%d')
  end

  paths.each do |path|
    zip_name = File.basename(path)

    Zip::File.open(path) do |zipfile|
      entry = zipfile.entries.first

      xsd_name = entry.name

      match = nil
      xsd_patterns.find do |pattern|
        match = xsd_name.match(pattern)
      end
      assert("unrecognized filename pattern #{xsd_name}"){match}

      contents = zipfile.read(entry)
      basename = "#{match[1]}_#{match[2]}.xsd"
      filename = nil

      if cache.key?(basename)
        others = cache[basename]
        if others.none?{|other| other[:contents] == contents}
          puts "expected #{zip_name}##{xsd_name} to equal #{others.map{|other| "#{other[:zip]}##{other[:xsd]}"}.join(' or ')}"
          filename = File.join(docs, 'xsd', "#{basename}.#{others.size}")
        end
      else
        filename = File.join(docs, 'xsd', basename)
      end

      if filename
        File.open(filename, 'w') do |f|
          f.write(contents)
        end

        cache[basename] ||= []
        cache[basename] << {
          contents: contents,
          zip: zip_name,
          xsd: xsd_name,
        }
      end
    end
  end
end

desc 'Generates SVG from XSD'
task :svg do
  # @see http://xsdvi.sourceforge.net/
  Dir.chdir(File.join(docs, 'svg')) # so that the SVG appear in the correct directory.
  `java -jar #{File.join('..', '..', 'jar', 'xsdvi.jar')} #{Dir[File.join(docs, 'xsd', '*')].join(' ')}`
end
