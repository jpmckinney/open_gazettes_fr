## Development

Run the scraper:

    TURBOT_ENV=development ruby scraper.rb

The `data` directory is structured to match the output of:

    wget -r ftp://echanges.dila.gouv.fr/BODACC/

If the documentation is downloaded by `wget`, extract the XSD:

    rake xsd

Generate SVG from XSD (requires Java):

    rake svg

You can open the SVG files in your browser.

## Documentation

* [BODACC editions](http://www.bodacc.fr/Bodacc/Mieux-connaitre-le-Bodacc#Avis)

## XML Schema

On 2013-05-24, `RCI_V10.xsd` was updated to change the `maxLength` of `NomDenomination_Type` from `200` to `1000`, but the version number of the XSD file was not changed.
