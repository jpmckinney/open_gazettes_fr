# coding: utf-8

TOP_LEVEL_NODE = {
  'RCS-A' => 'RCS_A_IMMAT', # XSD has "RCS-A_IMMAT"
  'PCL' => 'PCL_REDIFF',
  'DIV' => 'Divers_XML_Rediff',
  'RCS-B' => 'RCS_B_REDIFF', # XSD has "RCS_B_REDIFF"
  'BILAN' => 'Bilan_XML_Rediff',
}.freeze

TYPES = {
  'annonce' => nil,
  'creation' => nil,
  'rectificatif' => 'correction',
  'annulation' => 'cancellation',
}.freeze

ACT_TYPES = {
  'creation' => 'creation',
  'immatriculation' => 'registration',
  'vente' => 'sale',
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

CURRENCY_CODES = {
  'eur' => 'EUR',
  'euros' => 'EUR',
  'francs francais' => 'FRF',
  'francs français' => 'FRF',
}.freeze

PROPERTY_TYPES = {
  # Primary
  'etablissement pricipal' => 'primary',
  'etablissement principal' => 'primary',
  'etablissement principale' => 'primary',
  'etablissemnt principal' => 'primary',
  'ets principal' => 'primary',
  'pincipal' => 'primary',
  'pricipal' => 'primary',
  'principal' => 'primary',
  'établissement principal' => 'primary',
  'établissements principal' => 'primary',
  'établissment principal' => 'primary',
  # Secondary
  'etablissement secondaire' => 'secondary',
  'secondaire' => 'secondary',
  'établissement secondaire' => 'secondary',
  # Other
  'etablissement complémentaire' => 'other',
}.freeze

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

CATEGORIES = Set.new([
  "Autre immatriculation personne morale",
  "Autre immatriculation personne physique",
  "Immatriculation d'une personne morale (B, C, D) suite à création d'un établissement principal",
  "Immatriculation d'une personne morale (B, D) sans activité",
  "Immatriculation d'une personne physique suite à création d'un établissement principal",
  "Transformation d'un GAEC",
]).freeze

# This covers all downcased origins without amounts occurring at least twice in
# 2015. For origins with amounts, see `PROPERTY_ORIGINS_RE`. Note that in either
# case, the origin may be prefixed by:
#
# /\Aimmatriculation d'une personne (?:morale|physique) après 1er avis/
#
# After removing this prefix (whether or not it is present) the origin may be
# prefixed by:
#
# /\a\. /
#
# In other words, you should match and remove these prefixes in this order
# before matching the origin against `PROPERTY_ORIGINS` or `PROPERTY_ORIGINS_RE`.
#
# @example
#   match = origin.match(/\Aimmatriculation d'une personne (morale|physique) après 1er avis/, '')
#   if match
#     entity_type = match[1] == 'morale' ? 'company' : 'person'
#   end
#   origin.sub!(/\a\. /)
#   if PROPERTY_ORIGINS.include?(origin)
#     # ...
#   else
#     match = origin.match(PROPERTY_ORIGINS_RE)
#     if match
#       # ...
#     end
#   end
PROPERTY_ORIGINS = Set.new([
  "achat (sans bodacc)",
  "achat d'un fonds artisanal (sans opposition)",
  "achat d'un fonds artisanal",
  "achat d'un fonds de commerce",
  "achat d'une clientèle civile (sans opposition)",
  "achat dans le cadre d'un plan de cession",
  "achat dans le cadre d'une liquidation judiciaire",
  "achat dans le cadre d'une procédure collective",
  "achat de droit au bail",
  "achat",
  "achat.",
  "acquis par achat",
  "acquisition par fusion",
  "acquisition par scission",
  "activité exercée dans l'attente de l'accomplissement des actes",
  "adjudication",
  "apport (sans bodacc)",
  "apport d'exploitation(s) individuelle(s)",
  "apport d'un fonds artisanal sans déclaration de créances",
  "apport d'un fonds artisanal",
  "apport d'un fonds de commerce",
  "apport d'une clientèle civile sans déclaration de créances",
  "apport fusion",
  "apport partiel d'actif",
  "apport",
  "autre",
  "avis au bodacc relatif au projet commun de fusion nationale",
  "avis de projet d'apport partiel d'actif",
  "avis de projet de fusion",
  "concession",
  "contrat d'affermage",
  "convention d'occupation",
  "creation",
  "création d'un fonds de commerce",
  "création",
  "donation (sans oppositions)",
  "donation",
  "etablissement principal acquis par achat",
  "fond transferé",
  "fonds acquis dans le cadre d'un plan de cession",
  "fonds acquis par achat",
  "fonds acquis par achat.",
  "fonds acquis par apport partiel d'actif",
  "fonds acquis par apport",
  "fonds acquis par fusion",
  "fonds acquis par scission",
  "fonds de commerce reçu en location gérance",
  "fonds exploité dans le cadre d'un contrat de mandat",
  "fonds hérité",
  "fonds précédemment exploité en location-gérance, acquis par achat",
  "fonds précédemment exploité par le conjoint",
  "fonds principal acquis par achat",
  "fonds repris après location-gérance",
  "fonds reçu en location-gérance",
  "fonds reçu par donation",
  "fonds transféré",
  "gestion de l'entreprise confiée dans l'attente de l'accomplissement des actes necessaires a la réalisation de la cession",
  "héritage",
  "immatriculation d'une personne morale sans activité",
  "immatriculation d'une personne morale suite à création d'un établissement principal",
  "immatriculation d'une personne morale, établissement principal reçu en location-gérance",
  "immatriculation d'une personne physique suite à création d'un fonds",
  "immatriculation d'une personne physique, fonds reçu en location-gérance",
  "immatriculation suite à transfert du fonds hors ressort",
  "immatriculation suite à transfert du siège social hors ressort",
  "licitation",
  "location-gérance",
  "mandat et location-gérance",
  "mandat-gérance",
  "mise en activité de l'établissement principal suite à achat",
  "mutation entre époux",
  "partage",
  "prise en gérance-mandat",
  "prise en location-gérance",
  "projet commun d'apport partiel d'actif",
  "projet commun de fusion nationale",
  "projet d'apport partiel d'actif place sous le régime des scissions",
  "projet d'apport partiel d'actif placé sous le régime des scissions",
  "projet d'apport partiel d'actif",
  "projet de fusion",
  "projet de scission",
  "prêt à usage ou commodat",
  "reprise (sans bodacc)",
  "reprise d'activité après location-gérance",
  "reprise d'exploitation après fin de location-gérance",
  "reprise d'une activité saisonnière",
  "reprise",
  "reçu en location-gérance",
  "réimmatriculation à la suite d'une radiation faite par erreur",
  "résiliation de bail des locaux",
  "transfert d'activité dans le ressort",
  "transfert d'activité",
  "transfert d'établissement dans le ressort",
  "transfert d'établissement",
  "transfert de siège",
  "transfert",
  "transformation d'un gaec en earl",
  "transformation d'un gaec",
  "transmission universelle du patrimoine à l'associé unique",
  "transmission universelle du patrimoine",
]).freeze

# The prior purchase price of the property isn't modeled, among other facts contained here.
# @see http://www.lecoindesentrepreneurs.fr/le-contrat-de-vente-de-fonds-de-commerce/
PROPERTY_ORIGINS_RE = /
  \A
  # Description
  (?:(?:
    achat\sd'un\sfonds\sartisanal\s\(sans\sopposition\)|
    achat\sd'un\sfonds\sartisanal|
    achat\sd'un\sfonds\sde\scommerce\ssans\sdroit\sau\sbail|
    achat\sd'un\sfonds\sde\scommerce|
    achat\sd'un\sfonds|
    achat\sd'une\sbranche\sd'activité|
    achat\sd'éléments\sde\sfonds|
    achat\sde\sdroit\sau\sbail|
    achat\sdu\sfonds\sde\scommerce|
    achat\sdu\sfonds|
    achat\set\scréation|
    achat|
    acquisition\sd'une\slicence|
    acquisition\spar\sfusion|
    adjudication|
    apport\s\(avec\sbodacc\)|
    apport\sd'un\sfonds\sartisanal|
    apport\sd'un\sfonds\sde\scommerce|
    apport\sen\sjouissance\sdu\sfond|
    apport\sen\ssociété|
    apport\spartiel\sd'actif|
    apport|
    branche\sd'activité|
    cession|
    clientèle\scivile|
    création\set\sapport|
    création|
    divers|
    donation\sd'un\sfonds\sde\scommerce|
    droit\sau\sbail|
    echange\sd'un\sfonds|
    etablissement\scomplémentaire|
    etablissement\sprincipal\sachat\sde\sdroit\sau\sbail|
    etablissement\sprincipal\sapport\sd'exploitation\sindividuelle|
    etablissement\sprincipal\sclientèle\scivile|
    etablissement\sprincipal\sfonds\sartisanal|
    etablissement\sprincipale?|
    etablissement\ssecondaire\sclientèle\scivile|
    etablissement\ssecondaire\sfonds\sartisanal|
    etablissement\ssecondaire|
    etablissement|
    fonds\sachat\sde\sdroit\sau\sbail|
    fonds\sartisanal|
    fonds\scomplémentaire|
    fonds\sde\scommerce|
    fonds\sfonds\sartisanal|
    fonds\slicence\sacquise|
    fonds\slégué|
    fonds\sprincipal|
    fonds\sreçu|
    fonds\ssecondaire|
    fonds|
    fond|
    licitation|
    liquidation-partage|
    mise\sen\sactivité\sde\sl'établissement\sprincipal|
    mise\sen\sactivité\sde\sla\ssociété\ssuite\sà\sl'achat\sde\sl'établissement\sprincipal|
    nouvelle\sbranche\sd'activité.\sfonds|
    partage\sde\sla\scommunauté|
    partage|
    reprise\ssuivant\sla\srésolution\sde\sla\svente|
    résiliation\sde\sbail|
    résiliation\sde\sbail\sdes\slocaux
  )\s)?

  # Previous
  (?:précédemment\sexploité\sen\slocation-gérance,?\s)?

  # Either "acquis par…", "acquis dans…" or "acquis par… dans…"
  (?:(?:d')?acquis\s)?

  # Method
  (?:par\s(?:
    achat,\scession,\sattribution\spar\spartage\sou\spar\slicitation|
    achat,\scession|
    achat|
    adjudication|
    apport|
    apport\spartiel\sd'actif|
    attribution\saprès\spartage\sde\sla\scommunauté|
    attribution\ssuite\sà\sdissolution|
    donation|
    donation\savec\sdélai\sd'opposition|
    donation\ssans\soppositions|
    licitation|
    fusion|
    partage|
    transmission\suniverselle\sde\spatrimoine
  ),?\s)?

  # Context
  (?:dans\sle\scadre\s(?:
    d'un\splan\sde\scession|
    d'une\sliquidation\sjudiciaire|
    d'une\sprocédure\scollective
  )\s)?

  (?:(?:
    aux?\sprix(?:\sglobal)?(?:\sstipulé)?\sde(?:\s?[:,])?|
    au\smontant\sévalué(?:\sà)?|
    de|
    évalué\sà|
    moyennant\s(?:le\sprix|une\sindemnité)\sde|
    pour\sun\s(?:montant|prix)\sde
  )\s)?

  # Purchase price
  [\d.,\s]+\s(?:eur|euros?|francs)\.?
  \z

  |

  \A
  (?:(?:
    achat|
    fonds\sacquis\spar\sachat
  )\.\s)?
  date\sdu\spremier\savis\spublié\sau\sbodacc\s:\s\d+\s\S+\s\d+
  \z
/x
