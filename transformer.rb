# coding: utf-8

require_relative 'framework'

require 'active_support/core_ext/hash/deep_merge'
require 'nokogiri'
require 'nori'

class FR_BODACC < Framework::Processor
  TOP_LEVEL_NODE = {
    'RCS-A' => 'RCS_A_IMMAT',
    'PCL' => 'PCL_REDIFF',
    'DIV' => 'Divers_XML_Rediff',
    'RCS-B' => 'RCS_B_REDIFF', # XML schema has it wrong
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

      data = issue.fetch('other_attributes').fetch('data')
      xml = Nokogiri::XML(data, nil, 'utf-8')
      json = parser.parse(data.encode('iso-8859-1')).fetch(TOP_LEVEL_NODE.fetch(format))

      identifier = json.fetch('parution')
      expected = if format == 'DIV'
        issue['identifier'][0, 4] + issue['identifier'][-4, 4]
      else
        issue['identifier']
      end
      assert("expected #{expected}, got #{identifier}"){identifier == expected}

      date_published = json.fetch('dateParution')
      case date_published
      when %r{/\d{4}\z}
        date_published = Date.strptime(date_published, '%d/%m/%Y')
      when %r{\A\d{4}/}
        date_published = Date.strptime(date_published, '%Y/%m/%d')
      else
        date_published = Date.strptime(date_published, '%Y-%m-%d')
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
        other_attributes: {
          format: format,
        },
      }

      if format == 'PCL'
        xml_items = xml.xpath('//annonces/annonce')
        json_items = to_array(json.fetch('annonces').fetch('annonce'))
      else
        xml_items = xml.xpath('//listeAvis/avis')
        json_items = to_array(json.fetch('listeAvis').fetch('avis'))
      end

      json_items.each_with_index do |node,index|
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
        xml_node = xml_items[index]
        case format
        when 'RCS-A'
          parse_div_a(node, xml_node, record)
        when 'PCL'
          parse_pcl(node, xml_node, record)
        when 'DIV'
          parse_div(node, xml_node, record)
        when 'RCS-B'
          parse_rcs_b(node, xml_node, record)
        when 'BILAN'
          parse_bilan(node, xml_node, record)
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

  # XXX review schema
  def parse_div_a(node, xml_node, record)
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

      # @see https://github.com/openc/openc-schema/issues/39
      # capital(personne)

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

    record[:other_attributes][:previous_owners] = to_array(node['precedentProprietairePM']).map do |subnode|
      moral_person(subnode)
    end
    record[:other_attributes][:previous_owners] += to_array(node['precedentProprietairePP']).map do |subnode|
      physical_person(subnode)
    end

    record[:other_attributes][:previous_operators] = to_array(node['precedentExploitantPM']).map do |subnode|
      moral_person(subnode)
    end
    record[:other_attributes][:previous_operators] += to_array(node['precedentExploitantPP']).map do |subnode|
      physical_person(subnode)
    end

    act_type = node.fetch('acte').keys.first # "creation", "immatriculation", "vente"
    subnode = node.fetch('acte').fetch(act_type) || {}
    if act_type == 'creation' # required by XML schema, but sometimes missing
      record[:classification] = [{
        scheme: 'fr_bodacc',
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

  def parse_pcl(node, xml_node, record)
    default_entity_properties = {
      identifiers: [],
      alternative_names: [],
    }

    # I have no idea what this is. The identifiers are nowhere on the internet.
    record[:other_attributes][:client_identifier] = node.fetch('identifiantClient')

    record[:subjects] = []

    entity_type = nil
    entity_properties = Marshal.load(Marshal.dump(default_entity_properties))

    xml_node.xpath('./identifiantClient/following-sibling::*').each do |sibling|
      # Instead of nesting related nodes, PCL uses node order to group nodes.
      if %w(personneMorale personnePhysique).include?(sibling.name)
        if entity_type
          record[:subjects] << {
            entity_type: entity_type,
            entity_properties: entity_properties,
          }
          entity_type = nil
          entity_properties = Marshal.load(Marshal.dump(default_entity_properties))
        end
      end

      subnode = parser.parse(sibling.to_s).fetch(sibling.name)

      case sibling.name
      when 'personneMorale'
        entity_type = 'company'
        entity_properties[:name] = subnode.fetch('denomination')
        entity_properties[:company_type] = subnode['formeJuridique']
        if subnode.key?('sigle')
          entity_properties[:alternative_names] << {
            company_name: subnode['sigle'],
            type: 'abbreviation',
          }
        end

      when 'personnePhysique'
        entity_type = 'person'
        if subnode.key?('nom') && subnode.key?('denominationEIRL')
          warn("expected one of nom or denominationEIRL, got both")
        end
        entity_properties[:name] = if subnode.key?('nom')
          {
            family_name: subnode['nomUsage'] || subnode['nom'],
            given_name: subnode['prenom'],
            birth_name: subnode['nom'],
          }
        else
          subnode.fetch('denominationEIRL')
        end

      when 'numeroImmatriculation'
        entity_properties[:identifiers] << {
          uid: "#{subnode.fetch('numeroIdentificationRCS')} #{subnode.fetch('codeRCS')} #{subnode.fetch('nomGreffeImmat')}",
          identifier_system_code: "fr_bodacc_#{subnode.fetch('codeRCS').downcase}",
        }

      when 'nonInscrit'
        # Do nothing.

      when 'inscriptionRM'
        entity_properties[:identifiers] << {
          uid: "#{subnode.fetch('numeroIdentificationRM')} #{subnode.fetch('codeRM')} #{subnode.fetch('numeroDepartement')}",
          identifier_system_code: "fr_bodacc_#{subnode.fetch('codeRM').downcase}",
        }

      when 'enseigne'
        entity_properties[:alternative_names] << {
          company_name: subnode,
          type: 'unknown', # nomCommercial is "trading", sigle is "abbreviation"
        }

      when 'activite'
        # @see https://github.com/openc/openc-schema/issues/39
        # subnode

      when 'adresse'
        entity_properties[:registered_address] = address(subnode)

      when 'jugement', 'jugementAnnule'
        break

      else
        error("unexpected node #{sibling.name}")
      end
    end

    if node.key?('jugement') && node.key?('jugementAnnule')
      warn("expected one of jugement or jugementAnnule, got both")
    end

    # If the `update_action.type` is "cancellation", then `jugementAnnule`
    # is used instead of `jugement`.
    record[:about] = if node.key?('jugement')
      judgment(node['jugement'])
    else
      judgment(node.fetch('jugementAnnule'))
    end
  end

  def parse_div(node, xml_node, record)
    record[:title] = node['titreAnnonce']
    record[:body] = {
      value: node.fetch('contenuAnnonce'),
      media_type: 'text/plain',
    }
  end

  def parse_rcs_b(node, xml_node, record)
    record[:subjects] = to_array(node.fetch('personnes').fetch('personne')).map do |subnode|
      if subnode.key?('personneMorale') && subnode.key?('personnePhysique')
        warn("expected one of personneMorale or personnePhysique, got both")
      end

      properties = subnode.slice('numeroImmatriculation', 'nonInscrit', 'activite', 'adresse', 'siegeSocial', 'etablissementPrincipal')

      if subnode.key?('personneMorale')
        company(subnode['personneMorale'].merge(properties))
      else
        person(subnode.fetch('personnePhysique').merge(properties))
      end
    end

    if node.key?('modificationsGenerales') && node.key?('radiationAuRCS')
      warn("expected one of modificationsGenerales or radiationAuRCS, got both")
    end

    # If the `update_action.type` is "cancellation", `modificationsGenerales`
    # or `radiationAuRCS` is empty.
    if node.key?('modificationsGenerales')
      subnode = node['modificationsGenerales']
      if subnode
        record[:about] = {
          kind: 'general modifications',
          activity_start_date: date_format(subnode['dateCommencementActivite']),
          effective_date: date_format(subnode['dateEffet']),
          body: {
            value: subnode.fetch('descriptif'),
            media_type: 'text/plain',
          },
        }

        record[:about][:previous_operators] = to_array(subnode['precedentExploitantPM']).each do |entity|
          company(entity, required: true)
        end

        record[:about][:previous_operators] += to_array(subnode['precedentExploitantPP']).each do |entity|
          person(entity)
        end
      end
    elsif node.key?('radiationAuRCS')
      subnode = node['radiationAuRCS']
      if subnode
        if subnode.key?('radiationPP') && subnode.key?('radiationPM')
          warn("expected one of radiationPP or radiationPM, got both")
        end

        record[:about] = {
          kind: 'struck off',
        }
        if subnode.key?('radiationPP')
          record[:about][:activity_end_date] = date_format(subnode['radiationPP'].fetch('dateCessationActivitePP'))
        else
          subnode.fetch('radiationPM') # Is always equal to "O".
        end
        if subnode.key?('commentaire')
          record[:about][:body] = {
            value: subnode['commentaire'],
            media_type: 'text/plain',
          }
        end
      end
    end
  end

  def parse_bilan(node, xml_node, record)
    record[:subjects] = [company(node, required: true)]

    if node.key?('depot')
      value = {
        kind: 'filing',
        classification: [{
          scheme: 'fr_bodacc_typeDepot',
          value: node['depot'].fetch('typeDepot'), # code list
        }],
        closing_date: date_format(node['depot'].fetch('dateCloture')),
      }

      if node['depot'].key?('descriptif')
        value[:body] = {
          value: node['depot']['descriptif'],
          media_type: 'text/plain',
        }
      end

      record[:about] = value
    end
  end



  ### Helpers

  # @return [Nori] an XML-to-JSON parser
  def parser
    @parser ||= Nori.new(advanced_typecasting: false)
  end

  # @param [Hash] hash a hash
  # @return [Hash] a hash without keys with null values
  def compact(hash)
    hash.each do |key,value|
      case value
      when Array
        hash[key] = value.map do |v|
          compact(v)
        end
      when Hash
        hash[key] = compact(value)
      end
    end

    hash.reject do |_,value|
      case value
      when Array
        value.empty?
      when Hash
        value.empty?
      else
        value.nil?
      end
    end
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
  # @return [Hash] the values of the company
  def company(hash, options = {})
    entity_properties = registration(hash, options).merge({
      name: hash.fetch('denomination'),
      alternative_names: [],
      company_type: hash['formeJuridique'],
      # @see https://github.com/openc/openc-schema/issues/39
      # capital(hash)
    })

    # XXX remove after finishing rcs_a
    if hash['capital']
      debug(hash['capital'])
    end

    # TODO Handle other formats of `administration`.
    if hash['administration'] && !hash['administration'][/\b(?:Modification de la désignation d'un dirigeant : |devient|n'est plus)\b/]
      parts = hash['administration'].split(DIRECTORS_RE)
      parts[1..-2] = parts[1..-2].flat_map{|part| part.split(DIRECTOR_ROLES_RE, 2)}

      if parts.size.even?
        entity_properties[:officers] = parts.each_slice(2) do |position,name|
          {
            name: name,
            position: position,
          }
        end
      elsif hash['administration'][':']
        debug("administration: #{parts.inspect}")
      end
    end

    if hash.key?('nomCommercial')
      entity_properties[:alternative_names] << {
        company_name: hash['nomCommercial'],
        type: 'trading',
      }
    end
    if hash.key?('sigle')
      entity_properties[:alternative_names] << {
        company_name: hash['sigle'],
        type: 'abbreviation',
      }
    end

    # @see https://github.com/openc/openc-schema/issues/39
    # hash['activite']

    entity_properties[:registered_address] = address(hash['adresse'])
    entity_properties[:headquarters_address] = address(hash['siegeSocial'])
    entity_properties[:mailing_address] = address(hash['etablissementPrincipal'])

    {
      entity_type: 'company',
      entity_properties: entity_properties,
    }
  end

  # @param [Hash] hash a hash
  # @param [Hash] options options
  # @option options [Boolean] :required whether a registration is required
  # @return [Hash] the values of the person
  def person(hash, options = {})
    entity_properties = registration(hash, options).merge({
      name: {
        family_name: hash['nomUsage'] || hash.fetch('nom'),
        given_name: hash.fetch('prenom'),
        birth_name: hash.fetch('nom'),
      },
      alternative_names: [],
      # XXX add comment after finishing rcs_a
      # hash['nationnalite']
    })

    # XXX remove after finishing rcs_a
    if hash['nationnalite']
      debug("nationnalite: #{hash['nationnalite'].inspect}")
    end

    # TODO `nature` is never set, so I don't know how to interpret it now, in
    # case it is ever set later.
    if hash['nature']
      debug("nature: #{hash['nature'].inspect}")
    end

    if hash.key?('pseudonyme')
      entity_properties[:alternative_names] << {
        company_name: hash['pseudonyme'],
        type: 'unknown',
      }
    end
    if hash.key?('nomCommercial')
      entity_properties[:alternative_names] << {
        company_name: hash['nomCommercial'],
        type: 'trading',
      }
    end

    # @see https://github.com/openc/openc-schema/issues/39
    # hash['activite']

    entity_properties[:registered_address] = address(hash['adresse'])
    entity_properties[:headquarters_address] = address(hash['siegeSocial'])
    entity_properties[:mailing_address] = address(hash['etablissementPrincipal'])

    {
      entity_type: 'person',
      entity_properties: entity_properties,
    }
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

      {
        company_number: "#{node['numeroIdentification'] || node.fetch('numeroIdentificationRCS')} #{node.fetch('codeRCS')} #{node.fetch('nomGreffeImmat')}",
      }
    elsif options[:required] && hash.fetch('nonInscrit')
      {}
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
          value: node['montantCapital'],
          currency: node.fetch('devise'),
        }
      else
        {
          value: node.fetch('capitalVariable'),
        }
      end
    end
  end

  # @param [Hash] hash a hash
  # @return [Hash] the values of the judgment
  def judgment(hash)
    value = {
      kind: 'judgment',
      classification: [{
        scheme: 'fr_bodacc_famille',
        value: hash.fetch('famille'), # code list
      }, {
        scheme: 'fr_bodacc_nature',
        value: hash.fetch('nature'), # code list
      }],
      date: date_format(hash['date'], ['%e %B %Y']),
    }

    if hash.key?('complementJugement')
      value[:body] = {
        value: hash['complementJugement'],
        media_type: 'text/plain',
      }
    end

    value
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

        {
          street_address: node.fetch('adresse'), # a complete address
          country_name: node['pays'],
        }
      end
    end
  end

  # @param [Hash] hash a hash
  # @return [Hash] the values of the French address
  def france_address(hash)
    if hash
      {
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
      }
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
