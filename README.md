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
