# coding: utf-8

require_relative 'framework'

require 'active_support/core_ext/hash/deep_merge'
require 'nokogiri'

class FR_BODACC < Framework::Processor
  TOP_LEVEL_NODE = {
    'RCS-A' => 'RCS_A_IMMAT',
    'PCL' => 'PCL_REDIFF',
    'DIV' => 'Divers_XML_Rediff',
    'RCS-B' => 'RCS_B_REDIFF',
    'BILAN' => 'Bilan_XML_Rediff',
  }.freeze

  TYPES = {
    'annonce' => nil,
    'creation' => nil,
    'rectificatif' => 'correction',
    'annulation' => 'cancellation',
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

      if format == 'PCL'
        nodes = to_array(document.fetch('annonces').fetch('annonce'))
        xml = Nokogiri::XML(issue.fetch('other_attributes').fetch('xml'), nil, 'utf-8').xpath('/PCL_REDIFF/annonces/annonce')
        assert("expected the number of XML nodes (#{xml.size}) to be the number of JSON nodes (#{nodes.size})"){xml.size == nodes.size}
      else
        nodes = to_array(document.fetch('listeAvis').fetch('avis'))
      end

      nodes.each_with_index do |node,index|
        record = Marshal.load(Marshal.dump(default_record))

        type_raw = node.fetch('typeAnnonce').keys.first
        if format != 'DIV'
          type = TYPES.fetch(type_raw)
          if type
            subnode = node.fetch('parutionAvisPrecedent')

            record[:update_action] = {
              type: type,
              object: {
                issue: {
                  identifier: subnode.fetch('numeroParution'),
                  edition_id: subnode.fetch('nomPublication'),
                },
                date_published: date_format(subnode.fetch('dateParution'), ['%Y-%m-%d', '%e %B %Y']),
                identifier: Integer(subnode.fetch('numeroAnnonce')),
              },
            }
          else
            assert("expected parutionAvisPrecedent to be nil"){!node.key?('parutionAvisPrecedent')}
          end

          record[:publisher] = {
            name: node.fetch('tribunal').gsub("\n", " "),
            identifier: node.fetch('numeroDepartement'),
          }
        else
          assert("expected typeAnnonce to be 'annonce', got '#{type_raw}'"){type_raw == 'annonce'}
        end

        record[:uid] = node.fetch('nojo')
        record[:identifier] = Integer(node.fetch('numeroAnnonce'))
        record[:url] = "http://www.bodacc.fr/annonce/detail/#{record[:uid]}"
        record[:media_type] = 'text/html'

        # `record` is passed by reference.
        case format
        when 'RCS-A'
          parse_div_a(node, record)
        when 'PCL'
          parse_pcl(xml[index], record)
        when 'DIV'
          parse_div(node, record)
        when 'RCS-B'
          parse_rcs_b(node, record)
        when 'BILAN'
          parse_bilan(node, record)
        else
          error("unrecognized format #{format}")
        end

        unless ENV['TURBOT_QUIET']
          puts JSON.dump(compact(record))
        end
      end
    end
  end



  ### XML Schema

  # TODO review schema
  def parse_div_a(node, record)
    record[:other_attributes][:entities] = to_array(node.fetch('personnes').fetch('personne')).map do |personne|
      entity = {}

      if personne.key?('personneMorale')
        if personne.key?('personnePhysique')
          warn("expected one of personneMorale or personnePhysique, got both")
        end
        entity[:entity] = moral_person(personne['personneMorale'], required: true)
      else
        entity[:entity] = physical_person(personne.fetch('personnePhysique'), required: true)
      end

      entity[:capital] = capital(personne)

      entity[:address] = address(personne['adresse'])

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
      record[:other_attributes][:act][:effective_date] = date_format(subnode['dateEffet'], ['%e %B %Y'])
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
  end

  # TODO review schema
  def parse_pcl(node, record)
    if node.xpath('/personneMorale|/personnePhysique').size > 1
      # puts node.to_s(indent: 2)
      # puts
    end
    # TODO
=begin
    # The number of entities (`personneMorale`, `personnePhysique`) matches the
    # number of registrations (`numeroImmatriculation`, `nonInscrit`), `adresse`,
    # `inscriptionRM` and `enseigne`. The number of `activite` is unpredictable.
    # The order of `personneMorale` and `personnePhysique` matters, but this is
    # lost in the conversion to JSON.

    node.fetch('identifiantClient')

    moral_person(node['personneMorale'])
    physical_person(node['personnePhysique'])

    registration(node)
    'inscriptionRM'
      'numeroIdentificationRM'
      'codeRM'
      'numeroDepartement'
    'enseigne'
    'activite'
    'adresse'

    if node.key?('jugement') && node.key?('jugementAnnule')
      warn("expected one of jugement or jugementAnnule, got both")
    end

    if node.key?('jugement')
      judgment(node['jugement'])
    else
      judgment(node.fetch('jugementAnnule'))
    end
=end
  end

  def parse_div(node, record)
    record[:title] = node['titreAnnonce']
    record[:body] = {
      value: node.fetch('contenuAnnonce'),
      media_type: 'text/plain',
    }
  end

  # TODO review schema
  def parse_rcs_b(node, record)
    to_array(node.fetch('personnes').fetch('personne')).map do |personne|
      if personne.key?('personneMorale')
        if personne.key?('personnePhysique')
          warn("expected one of personneMorale or personnePhysique, got both")
        end
        # TODO
        moral_person(personne['personneMorale'])
      else
        # TODO
        physical_person(personne.fetch('personnePhysique'))
      end

      # TODO
      registration(personne, required: true) # TODO merge
      personne['activite']
      address(personne['adresse'])
      address(personne['siegSocial'])
      address(personne['etablissementPrincipal'])
    end

    # TODO
    if node.key?('modificationsGenerales') && node.key?('radiationAuRCS')
      warn("expected one of modificationsGenerales or radiationAuRCS, got both")
    end

    'modificationsGenerales'
    'radiationAuRCS'
  end

  def parse_bilan(node, record)
    entity = registration(node, required: true)
    entity[:name] = node.fetch('denomination')

    if node.key?('sigle')
      entity[:alternative_names] = [{
        company_name: node['sigle'],
        type: 'abbreviation',
      }]
    end

    entity[:company_type] = node['formeJuridique']

    entity[:registered_address] = address(node['adresse'])

    if node.key?('depot')
      entity[:filings] = [compact({
        date: date_format(node['depot'].fetch('dateCloture')),
        filing_type_name: node['depot'].fetch('typeDepot'),
        description: node['depot']['descriptif'],
      })]
    end

    record[:subjects] = [{
      entity_type: 'company',
      entity_properties: compact(entity),
    }]
  end



  ### Helpers

  # @param [Hash] hash a hash
  # @return [Hash] a hash without keys with null values
  def compact(hash)
    hash.select{|_,v| v}
  end

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
  # @param [Array<String>] patterns `strftime` format strings
  def date_format(value, patterns = ['%Y-%m-%d'])
    if value
      patterns.each do |pattern|
        if pattern['%B']
          value = value.sub(MONTH_NAMES_RE){|match| MONTH_NAMES.fetch(match)}.sub(/\A1er\b/, '1').gsub(/\p{Space}/, ' ')
        end
        date = Date.strptime(value, pattern) rescue false
        if date
          return date.strftime('%Y-%m-%d')
        end
      end
      error("expected #{value.inspect} to match one of #{patterns.inspect}")
    end
  end



  ### Sections

  # @param [Hash] hash a hash
  # @param [Hash] options options
  # @option options [Boolean] :required whether a registration is required
  # @return [Hash] the values of the moral person
  def moral_person(hash, options = {})
    value = {
      type: 'Moral person',
      name: hash.fetch('denomination'),
      alternative_names: [],

      # RCS-A only
      registration: registration(hash, options),

      # <personneMorale> in RCS-A, PCL, and RCS-B only
      company_type: hash['formeJuridique'],

      # <personneMorale> in RCS-A and RCS-B only
      directors: hash['administration'],

      # <personneMorale> in RCS-B only
      capital: capital(hash),
    }

    # <personneMorale> in RCS-A and RCS-B only
    if hash.key?('nomCommercial')
      value[:alternative_names] << {
        company_name: hash['nomCommercial'],
        type: 'trading',
      }
    end

    # <personneMorale> in RCS-A, PCL, and RCS-B only
    if hash.key?('sigle')
      value[:alternative_names] << {
        company_name: hash['sigle'],
        type: 'abbreviation',
      }
    end

    # TODO Handle the alternate format for `administration`.
    if hash['administration'] && !hash['administration'][/\b(?:Modification de la désignation d'un dirigeant : |devient|n'est plus)\b/]
      parts = hash['administration'].split(DIRECTORS_RE)
      parts[1..-2] = parts[1..-2].flat_map{|part| part.split(DIRECTOR_ROLES_RE, 2)}

      if parts.size.even?
        value[:directors] = Hash[*parts]
      elsif hash['administration'][':']
        debug("can't parse: #{parts.inspect}")
      end
    end

    compact(value)
  end

  # @param [Hash] hash a hash
  # @param [Hash] options options
  # @option options [Boolean] :required whether a registration is required
  # @return [Hash] the values of the physical person
  def physical_person(hash, options = {})
    value = {
      type: 'Physical person',
      family_name: hash.fetch('nom'),
      given_name: hash.fetch('prenom'),
      customary_name: hash['nomUsage'],
      alternative_names: [],

      # RCS-A only
      registration: registration(hash, options),

      # <precedentProprietairePP> and <precedentExploitantPP> in RCS-A only
      nature: hash['nature'],

      # <personnePhysique> in RCS-A only
      nationality: hash['nationnalite'],
    }

    # <personnePhysique> in RCS-A and RCS-B only
    if hash.key?('pseudonyme')
      value[:alternative_names] << {
        name: hash['pseudonyme'],
        type: 'unknown',
      }
    end
    if hash.key?('nomCommercial')
      value[:alternative_names] << {
        name: hash['nomCommercial'],
        type: 'trading',
      }
    end

    compact(value)
  end

  # @param [Hash] hash a hash
  # @param [Hash] options options
  # @option options [Boolean] :required whether a registration is required
  # @return [Hash] the values of the registration
  def registration(hash, options = {})
    if hash.key?('numeroImmatriculation') && hash.key?('nonInscrit')
      warn("expected one of numeroImmatriculation or nonInscrit, got both")
    end

    if hash.key?('numeroImmatriculation')
      node = hash['numeroImmatriculation']

      assert("expected codeRCS to be 'RCS', got #{node['codeRCS']}"){node.fetch('codeRCS') == 'RCS'}

      {
        company_number: node.fetch('numeroIdentification', node.fetch('numeroIdentificationRCS')),
        # @see https://github.com/openc/openc-schema/issues/39
        # other_attributes: {
        #   registrar: node.fetch('nomGreffeImmat'),
        # },
      }
    elsif options[:required]
      hash.fetch('nonInscrit') && {}
    else
      {}
    end
  end

  # @param [Hash] hash a hash
  # @return [Hash] the values of the capital
  def capital(hash)
    if hash.key?('capital')
      node = hash['capital']

      if node.key?('montantCapital') && node.key?('capitalVariable')
        warn("expected one of montantCapital or capitalVariable, got both")
      end

      if node.key?('montantCapital')
        {
          amount_value: node['montantCapital'],
          currency: node.fetch('devise'),
        }
      else
        {
          amount: node.fetch('capitalVariable'),
        }
      end
    end
  end

  # @param [Hash] hash a hash
  # @return [Hash] the values of the judgment
  def judgment(hash)
    value = {
      type: hash.fetch('famille'), # code list
      classification: hash.fetch('nature'), # code list
      date: date_format(hash['date'], '%e %B %Y'),
    }

    if hash.key?('complementJugement')
      value[:body] = {
        value: hash['complementJugement'],
        media_type: 'text/plain',
      }
    end

    compact(value)
  end

  # @param [Hash] hash a hash
  # @return [Hash] the values of the address
  def address(hash)
    if hash
      if hash.key?('france') && hash.key?('etranger')
        warn("expected one of france or etranger, got both")
      end

      if hash.key?('france')
        france_address(hash['france'])
      else
        node = hash.fetch('etranger')

        compact({
          street_address: node.fetch('adresse'), # a complete address
          country_name: node['pays'],
        })
      end
    end
  end

  # @param [Hash] hash a hash
  # @return [Hash] the values of the French address
  def france_address(hash)
    if hash
      compact({
        # In INSPIRE, the terms may be:
        # * locator_designator_address_number
        # * thoroughfare_type
        # * thoroughfare_name
        # * locator_designator_building_identifier
        # * locator_designator_postal_delivery_identifier
        # * address_area
        # * post_code
        # * admin_unit
        # * country_name
        # @see AddressRepresentation and LocatorDesignatorTypeValue in http://inspire.ec.europa.eu/documents/Data_Specifications/INSPIRE_DataSpecification_AD_v3.0.1.pdf
        street_address: [
          # complGeographique can be "1 &", "Batiment 6", etc.
          hash.values_at('complGeographique', 'numeroVoie', 'typeVoie', 'nomVoie').compact.join(' '),
          hash.values_at('BP', 'localite').compact.join(' '),
        ].reject(&:empty?).join("\n"),
        locality: hash.fetch('ville'),
        postal_code: hash.fetch('codePostal'), # can start with "0"
        country: 'France',
        country_code: 'FR',
      })
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
