# coding: utf-8

require_relative 'framework'

class FR_BODACC < Framework::Processor
  TOP_LEVEL_NODE = {
    'RCS-A' => 'RCS_A_IMMAT',
    'PCL' => 'PCL_REDIFF',
    'DIV' => 'Divers_XML_Rediff',
    'RCS-B' => 'RCS-B_REDIFF',
    'BILAN' => 'Bilan_XML_Rediff',
  }

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

  # "EX", "NOM COMMERCIAL", "PAR ABREVIATION", "Prénom usuel", "nom d'usage", "nom d'uasage", "représenté par"
  DIRECTORS_RE = /(?<! \(EX| par|CIAL|sage|suel|TION) : (?!RCS )/.freeze

  DIRECTOR_ROLES = [
    'Actionnaire',
    'Administrateur',
    'Associé',
    'Co-gérant',
    'Commissaire',
    'Conjoint',
    'Conseiller',
    'Contrôleur',
    'Directeur',
    'Dirigeant',
    'Fondé',
    'Gerant',
    'Gérant',
    'Gérante',
    'Indivisaire',
    'Liquidateur',
    'Membre',
    'Personne',
    'Président',
    'Représentant',
    'Responsable',
    'Réviseur',
    'Sans correspondance',
    'Secrétaire',
    'Société',
    'Surveillant',
    'Trésorier',
    'Vice-président',
  ].freeze

  DIRECTOR_ROLES_RE = / (?=\b(?:#{DIRECTOR_ROLES.join('|')})\b)/i.freeze

  def scrape
    STDIN.each_line do |line|
      issue = JSON.load(line)
      format = issue.fetch('other_attributes').fetch('format')

      unless ['RCS-A', 'DIV'].include?(format)
        # TODO Add support for other formats besides RCS-A.
        debug("Skipping #{format} #{issue['identifier']}")
        next
      end

      document = issue.fetch('other_attributes').fetch('data').fetch(TOP_LEVEL_NODE.fetch(format))

      identifier = document.fetch('parution')
      expected = if format == 'DIV'
        issue['identifier'][0, 4] + issue['identifier'][-4, 4]
      else
        issue['identifier']
      end
      assert("expected #{expected}, got #{identifier}"){identifier == expected}

      date_published = document.fetch('dateParution')
      date_published = case date_published
      when %r{/\d{4}\z}
        Date.strptime(date_published, '%d/%m/%Y')
      when %r{\A\d{4}/}
        Date.strptime(date_published, '%Y/%m/%d')
      else
        Date.strptime(date_published, '%Y-%m-%d')
      end
      date_published = date_published.strftime('%Y-%m-%d')

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
          identifier: issue.fetch('identifier'),
          edition_id: issue.fetch('edition_id'),
          url: issue['url'],
        },
        date_published: date_published,
        source_url: issue.fetch('default_attributes').fetch('source_url'),
        sample_date: issue.fetch('default_attributes').fetch('retrieved_at'),
        retrieved_at: issue.fetch('default_attributes').fetch('retrieved_at'),
        confidence: 'HIGH',
        other_attributes: {},
      }

      nodes = if format == 'PCL'
        document.fetch('annonces').fetch('annonce')
      else
        document.fetch('listeAvis').fetch('avis')
      end

      to_array(nodes).each do |node|
        record = Marshal.load(Marshal.dump(default_record))

        # RCS-A: "annonce", "rectificatif", "annulation"
        # PCL: "creation", "rectificatif", "annulation"
        # DIV: "annonce"
        # RCS-B: "annonce", "rectificatif", "annulation"
        # BILAN: "annonce", "rectificatif", "annulation"
        record[:other_attributes][:notice_type] = node.fetch('typeAnnonce').keys.first
        record[:uid] = node.fetch('nojo')
        record[:identifier] = Integer(node.fetch('numeroAnnonce'))

        record = case format
        when 'RCS-A'
          parse_div_a(node, record)
        when 'DIV'
          parse_div(node, record)
        end

        puts JSON.dump(record.select{|_,v| v})
      end
    end
  end

  def parse_div(node, record)
    record[:title] = node['titreAnnonce']
    record[:body] = {
      value: node.fetch('contenuAnnonce'),
      media_type: 'text/plain',
    }

    record
  end

  def parse_div_a(node, record)
    record[:other_attributes][:department_number] = node.fetch('numeroDepartement')
    record[:other_attributes][:tribunal] = node.fetch('tribunal').gsub("\n", " ")

    record[:other_attributes][:entities] = to_array(node.fetch('personnes').fetch('personne')).map do |personne|
      entity = {}

      if personne.key?('personneMorale')
        if personne.key?('personnePhysique')
          warn("expected one of personneMorale or personnePhysique, got both")
        end
        entity[:entity] = moral_person(personne['personneMorale'])
      elsif personne.key?('personnePhysique')
        entity[:entity] = physical_person(personne['personnePhysique'])
      else
        warn("expected one of personneMorale or personnePhysique, got none")
      end

      if personne.key?('capital')
        subnode = personne['capital']
        entity[:capital] = if subnode.key?('montantCapital')
          {
            amount_value: subnode['montantCapital'],
            currency: subnode.fetch('devise'),
          }
        else
          {
            amount: subnode.fetch('capitalVariable'),
          }
        end
      end

      if personne.key?('adresse')
        subnode = personne['adresse']
        entity[:address] = if subnode.key?('france')
          france_address(subnode['france'])
        elsif subnode.key?('etranger')
          {
            address: subnode['etranger'].fetch('adresse'),
            country_name: subnode['etranger']['pays'],
          }
        end
      end

      entity
    end

    record[:other_attributes][:establishments] = to_array(node['etablissement']).map do |subnode|
      {
        origin: subnode['origineFonds'],
        establishment_type: subnode['qualiteEtablissement'],
        activity: subnode['activite'],
        sign: subnode['enseigne'],
        address: france_address(subnode['adresse']),
      }
    end

    # <precedentProprietairePM> <precedentProprietairePP>
    record[:other_attributes][:previous_owners] = to_array(node['precedentProprietairePM']).map do |subnode|
      moral_person(subnode)
    end
    record[:other_attributes][:previous_owners] += to_array(node['precedentProprietairePP']).map do |subnode|
      physical_person(subnode)
    end

    # <precedentExploitantPM> <precedentExploitantPP>
    record[:other_attributes][:previous_operators] = to_array(node['precedentExploitantPM']).map do |subnode|
      moral_person(subnode)
    end
    record[:other_attributes][:previous_operators] += to_array(node['precedentExploitantPP']).map do |subnode|
      physical_person(subnode)
    end

    # <parutionAvisPrecedent>
    if node.key?('parutionAvisPrecedent')
      subnode = node['parutionAvisPrecedent']
      record[:other_attributes][:previous] = {
        issue: {
          identifier: subnode.fetch('numeroParution'),
          edition_id: subnode.fetch('nomPublication'),
        },
        date_published: date_format(subnode.fetch('dateParution'), '%e %B %Y'),
        identifier: Integer(subnode.fetch('numeroAnnonce')),
      }
    end

    # <acte>
    act_type = node.fetch('acte').keys.first # "creation", "immatriculation", "vente"
    subnode = node.fetch('acte').fetch(act_type) || {}
    if act_type == 'creation' # required by XML schema, but sometimes missing
      record[:classification] = [{
        scheme: 'fr-bodacc',
        value: subnode.fetch("categorie#{act_type.capitalize}"),
      }]
    end

    record[:other_attributes][:act] = {
      type: act_type,
      date_registered: date_format(subnode['dateImmatriculation']),
      start_date: date_format(subnode['dateCommencementActivite']),
    }
    record[:description] = subnode['descriptif']

    if ['immatriculation', 'vente'].include?(act_type)
      record[:other_attributes][:act][:effective_date] = date_format(subnode['dateEffet'], '%e %B %Y')
    end

    if act_type == 'vente'
      if subnode.key?('journal')
        record[:other_attributes][:act][:journal] = {
          title: subnode['journal'].fetch('titre'),
          date: date_format(subnode['journal'].fetch('date')),
        }
      end

      if subnode.key?('opposition') || subnode.key?('declarationCreance')
        record[:other_attributes][:act][:opposition] = subnode['opposition']
        record[:other_attributes][:act][:debt_declaration] = subnode['declarationCreance']
      elsif subnode.any?
        warn("expected one of opposition or declarationCreance, got none")
      end
    end

    record
  end

  ### Helpers

  # @param value a value
  # @return [Array] the value or an array containing the value
  def to_array(value)
    if Array === value
      value
    elsif value.nil?
      []
    else
      [value]
    end
  end

  # @param [String] value a date
  # @param [String] pattern a `strftime` format string
  def date_format(value, pattern = '%Y-%m-%d')
    if value
      if pattern['%B']
        value = value.gsub(MONTH_NAMES_RE){|match| MONTH_NAMES.fetch(match)}.sub(/\A1er\b/, '1').gsub(/\p{Space}/, ' ')
      end
      begin
        Date.strptime(value, pattern).strftime('%Y-%m-%d')
      rescue ArgumentError => e
        error("#{e}: #{value.inspect}")
      end
    end
  end

  # @param [Hash] hash a hash
  # @return [Hash] the values of the moral person
  def moral_person(hash)
    value = {
      type: 'Moral person',
      name: hash.fetch('denomination'),
      registration: registration_number(hash),

      # <personneMorale> only
      company_type: hash['formeJuridique'],
      alternative_names: [],
      directors: hash['administration'],
    }

    if hash['administration'] && !hash['administration'][/\b(?:Modification de la désignation d'un dirigeant : |devient|n'est plus)\b/]
      parts = hash['administration'].split(DIRECTORS_RE)
      parts[1..-2] = parts[1..-2].flat_map{|part| part.split(DIRECTOR_ROLES_RE, 2)}
      if parts.size.even?
        value[:directors] = Hash[*parts]
      elsif hash['administration'][':']
        debug("can't parse: #{parts.inspect}")
      end
    end

    if hash.key?('nomCommercial')
      value[:alternative_names] << {
        company_name: hash['nomCommercial'],
        type: 'trading',
      }
    end

    if hash.key?('sigle')
      value[:alternative_names] << {
        company_name: hash['sigle'],
        type: 'abbreviation',
      }
    end

    value
  end

  # @param [Hash] hash a hash
  # @return [Hash] the values of the physical person
  def physical_person(hash)
    {
      type: 'Physical person',
      family_name: hash.fetch('nom'),
      given_name: hash.fetch('prenom'),
      customary_name: hash['nomUsage'],
      registration: registration_number(hash),

      # <precedentProprietairePP> and <precedentExploitantPP> only
      nature: hash['nature'],

      # <personnePhysique> only
      alternative_names: [{
        name: hash['pseudonyme'],
      }, {
        name: hash['nomCommercial'],
      }],
      nationality: hash['nationalite'],
    }
  end

  # @param [Hash] hash a hash
  # @return [Hash] the values of the registration
  def registration_number(hash)
    if hash.key?('numeroImmatriculation')
      node = hash['numeroImmatriculation']
      {
        registered: true,
        number: node.fetch('numeroIdentification'),
        rcs: node.fetch('codeRCS'),
        clerk: node.fetch('nomGreffeImmat'),
      }
    elsif hash.key?('nonInscrit')
      {
        registered: false,
      }
    end
  end

  # @param [Hash] hash a hash
  # @return [Hash] the values of the address
  def france_address(hash)
    if hash
      # @see AddressRepresentation and LocatorDesignatorTypeValue in http://inspire.ec.europa.eu/documents/Data_Specifications/INSPIRE_DataSpecification_AD_v3.0.1.pdf
      {
        locator_designator_address_number: hash['numeroVoie'],
        thoroughfare_type: hash['typeVoie'],
        thoroughfare_name: hash['nomVoie'],
        locator_designator_building_identifier: hash['complGeographique'],
        locator_designator_postal_delivery_identifier: hash['BP'],
        address_area: hash['localite'],
        post_code: hash.fetch('codePostal'), # can start with "0"
        admin_unit: hash.fetch('ville'),
        country_name: 'France',
      }.select{|_,v| v}
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
