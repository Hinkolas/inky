# Third-party notices

Inky's original source code and documentation are licensed under MIT; see
`LICENSE`. The following material retains its own terms.

## GeoNames geographic data

`InkyCore/Sources/InkyCore/Resources/places.tsv` is derived from the
[GeoNames](https://www.geonames.org/) `cities15000` dataset, licensed under
[Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/).
The [legal code](https://creativecommons.org/licenses/by/4.0/legalcode) and
[GeoNames dataset documentation](https://download.geonames.org/export/dump/readme.txt)
describe those terms and the source format.

Inky modifies the dataset using `Scripts/places.swift`: it selects cities with
at least 100,000 inhabitants and capitals, keeps the largest city for a shared
name, selects name/country/time-zone fields, and derives country time-zone
shortcuts from the populations in the input. GeoNames does not endorse Inky.
The data is supplied without a warranty of accuracy, completeness or timeliness.
A notice is also included alongside the data in the InkyCore resource bundle.

## Runtime services and system frameworks

InkyCore has no external Swift package dependencies. AppKit, SwiftUI, SQLite,
ImageIO, CryptoKit and the other Apple frameworks used by Inky are supplied by
macOS or the Apple toolchain; their implementation sources are not vendored here.
SF Symbols are referenced by system symbol name rather than redistributed as
standalone artwork. Apple's software and assets retain Apple's terms.

Currency rates are fetched at runtime from the European Central Bank, credited
in the calculator settings and results. They are reference rates, may be stale,
and are not trading quotes. See the
[ECB copyright and disclaimer](https://www.ecb.europa.eu/services/using-our-site/disclaimer/html/index.en.html).
No live exchange-rate dataset is bundled in the source; test rates are fixtures.

Website icons are fetched at runtime from DuckDuckGo's icon service. Icons and
trademarks belong to their respective owners and are not covered by Inky's MIT
license. They are cached on the user's Mac and are not bundled in releases.

When adding a dependency, dataset or asset, record its source, version (when
applicable), license, required notices and modifications here before shipping it.
