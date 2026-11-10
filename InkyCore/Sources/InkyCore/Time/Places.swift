import Foundation

/// Somewhere with a time of its own: a city, a country or a time zone.
public struct Place: Sendable, Hashable {
    /// How it is shown: "Tokyo, Japan".
    public var name: String
    public var timeZone: TimeZone

    public init(name: String, timeZone: TimeZone) {
        self.name = name
        self.timeZone = timeZone
    }
}

/// The places a time may be asked for.
///
/// Cities of a hundred thousand people and more, and capitals, come from
/// GeoNames (see `Scripts/places.swift`). Then come the countries that keep
/// one time, the names of the time zones themselves, and their abbreviations.
/// Where two share a name, the one that came first has it: the larger city,
/// and a city before a country.
struct PlaceIndex: Sendable {
    private var places: [String: Place] = [:]
    /// The most words a name has.
    private var longest = 1

    /// The list that ships with Inky, read when a time is first asked for.
    static let shared: PlaceIndex = {
        guard let url = Bundle.module.url(forResource: "places", withExtension: "tsv"),
              let list = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("The list of places is missing")
            return PlaceIndex(list: "")
        }
        return PlaceIndex(list: list)
    }()

    /// `list` is in the format `Scripts/places.swift` writes. Countries are
    /// named in English and in the language of `locale`.
    init(list: String, locale: Locale = .current) {
        let english = Locale(identifier: "en_US")
        var countries: [(code: String, zone: TimeZone)] = []
        // Thousands of cities share a few hundred countries and zones.
        var countryNames: [String: String?] = [:]
        var zones: [String: TimeZone?] = [:]
        func zone(_ identifier: String) -> TimeZone? {
            if let known = zones[identifier] { return known }
            let zone = TimeZone(identifier: identifier)
            zones[identifier] = zone
            return zone
        }

        for line in list.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if line.hasPrefix("@") {
                guard fields.count == 2, let zone = zone(fields[1]) else { continue }
                countries.append((String(fields[0].dropFirst()), zone))
                continue
            }
            // A zone this Mac does not know yet is left out.
            guard fields.count >= 3, let zone = zone(fields[2]) else { continue }
            if countryNames[fields[1]] == nil {
                countryNames[fields[1]] = .some(locale.localizedString(forRegionCode: fields[1]))
            }
            let country = countryNames[fields[1]] ?? nil
            let place = Place(name: country.map { "\(fields[0]), \($0)" } ?? fields[0], timeZone: zone)
            add(place, as: fields[0])
            if fields.count > 3 { add(place, as: fields[3]) }
        }

        // What a city is also called. These are meant, so they take a name
        // that a smaller city has.
        for (alias, city) in Self.aliases {
            if let place = places[Self.key(city)] {
                add(place, as: alias, replacing: true)
            }
        }

        for (code, zone) in countries {
            let place = Place(name: locale.localizedString(forRegionCode: code) ?? code, timeZone: zone)
            for name in [english, locale].compactMap({ $0.localizedString(forRegionCode: code) }) + (Self.countryAliases[code] ?? []) {
                add(place, as: name)
            }
        }

        // "America/Argentina/Buenos_Aires" is known as "Buenos Aires".
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard let zone = TimeZone(identifier: identifier), let last = identifier.split(separator: "/").last else { continue }
            let name = last.replacingOccurrences(of: "_", with: " ")
            add(Place(name: name, timeZone: zone), as: name)
        }

        for (abbreviation, identifier) in TimeZone.abbreviationDictionary.sorted(by: { $0.key < $1.key }) {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            add(Place(name: abbreviation, timeZone: zone), as: abbreviation)
        }
        for name in ["UTC", "GMT", "Zulu"] {
            add(Place(name: "UTC", timeZone: .gmt), as: name)
        }
    }

    private mutating func add(_ place: Place, as name: String, replacing: Bool = false) {
        let key = Self.key(name)
        guard !key.isEmpty, replacing || places[key] == nil else { return }
        places[key] = place
        longest = max(longest, key.split(separator: " ").count)
    }

    /// The place with the longest name that starts at `index` and ends
    /// before `end`, and how many tokens its name took.
    func match(_ tokens: [Token], at index: Int, before end: Int) -> (place: Place, count: Int)? {
        var candidates: [(key: String, count: Int)] = []
        var key = ""
        var offset = index
        while offset < end, candidates.count < longest {
            let token = tokens[offset]
            if token.isWord {
                key += (key.isEmpty ? "" : " ") + Self.key(token.text)
                candidates.append((key, offset - index + 1))
            } else if key.isEmpty || !token.isAttached || !(token.isSymbol("-") || token.isSymbol("'")) {
                // Only the hyphen of "Winston-Salem" and the like goes on.
                break
            }
            offset += 1
        }
        for candidate in candidates.reversed() {
            if let place = places[candidate.key] {
                return (place, candidate.count)
            }
        }
        return nil
    }

    /// A name as it is looked up: in lowercase, without accents, its words
    /// one space apart. "São Paulo" and "sao paulo" are the same place.
    static func key(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    /// Short names, old names, and the German ones where they differ.
    static let aliases: [(alias: String, city: String)] = [
        ("NYC", "New York City"), ("New York", "New York City"), ("NY", "New York City"),
        ("SF", "San Francisco"), ("LA", "Los Angeles"), ("LDN", "London"),
        ("DC", "Washington"), ("Washington DC", "Washington"), ("Vegas", "Las Vegas"),
        ("Philly", "Philadelphia"), ("HK", "Hong Kong"), ("KL", "Kuala Lumpur"), ("Rio", "Rio de Janeiro"),
        ("Saigon", "Ho Chi Minh City"), ("Bombay", "Mumbai"), ("Bangalore", "Bengaluru"),
        ("Calcutta", "Kolkata"), ("Peking", "Beijing"), ("Kiev", "Kyiv"), ("Frankfurt", "Frankfurt am Main"),
        ("Cologne", "Köln"), ("München", "Munich"), ("Nürnberg", "Nuremberg"), ("Wien", "Vienna"),
        ("Genf", "Geneva"), ("Brüssel", "Brussels"), ("Den Haag", "The Hague"), ("Rom", "Rome"),
        ("Mailand", "Milan"), ("Neapel", "Naples"), ("Florenz", "Florence"), ("Prag", "Prague"),
        ("Warschau", "Warsaw"), ("Moskau", "Moscow"), ("Lissabon", "Lisbon"), ("Kopenhagen", "Copenhagen"),
        ("Athen", "Athens"), ("Tokio", "Tokyo"), ("Kairo", "Cairo"), ("Neu Delhi", "New Delhi"),
    ]

    private static let countryAliases: [String: [String]] = [
        "GB": ["UK", "Britain", "Great Britain", "England"],
        "NL": ["Holland"],
        "TR": ["Turkey"],
        "CZ": ["Czech Republic"],
        "KR": ["Korea"],
        "AE": ["UAE", "Emirates"],
    ]
}
