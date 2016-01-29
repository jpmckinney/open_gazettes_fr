# This file contains code for validating the XML according to the XML Schema.

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

# TODO If we want to validate the XML, we need to resolve this error, which may
# be related to the `ISO_Currency_Code_2001.xsd`:
#
#   simple type 'Devise_Type', attribute 'base': The QName value
#   '{urn:un:unece:uncefact:codelist:standard:5:4217:2001}CurrencyCodeContentType'
#   does not resolve to a(n) simple type definition.

_, version = VERSIONS.find do |start_date,_|
  start_date < date_published
end

basename = SCHEMAS.fetch(format) % version.fetch(format)
schema = Nokogiri::XML::Schema(File.read(File.expand_path(File.join('docs', 'xsd', basename), Dir.pwd)))
schema.validate(document).each do |error|
  warn(error.message)
end
