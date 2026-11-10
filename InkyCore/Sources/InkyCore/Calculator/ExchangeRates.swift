import Foundation
import Observation

/// Where exchange rates come from.
public enum ExchangeRateSource: String, Sendable, CaseIterable, Identifiable {
    /// The reference rates of the European Central Bank: about thirty
    /// currencies against the euro, set on every working day.
    case ecb
    /// No requests are made, and currencies are not converted.
    case off

    public var id: Self { self }

    public var title: String {
        switch self {
        case .ecb: "European Central Bank"
        case .off: "None"
        }
    }

    /// The file with every rate. Nothing is sent but the request for it.
    var url: URL? {
        switch self {
        case .ecb: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")
        case .off: nil
        }
    }

    func rates(in data: Data) -> ExchangeRates? {
        switch self {
        case .ecb: ExchangeRates(ecb: data)
        case .off: nil
        }
    }
}

/// What currencies were worth on one day.
public struct ExchangeRates: Sendable, Equatable {
    /// The day the rates are of, at noon in Greenwich, so it is the same day
    /// almost anywhere.
    public var day: Date
    /// How much of each currency one euro buys, by its code. The euro is in
    /// here too.
    public var perEuro: [String: Double]

    public init(day: Date, perEuro: [String: Double]) {
        self.day = day
        self.perEuro = perEuro
    }

    /// Reads the daily file of the European Central Bank:
    ///
    ///     <Cube time='2026-11-10'>
    ///         <Cube currency='USD' rate='1.1214'/>
    public init?(ecb data: Data) {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let day = reader.day, !reader.rates.isEmpty else { return nil }
        self.day = day
        perEuro = reader.rates.merging(["EUR": 1]) { rate, _ in rate }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var day: Date?
        var rates: [String: Double] = [:]

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            guard elementName == "Cube" else { return }
            if let time = attributes["time"] {
                day = Self.day(time)
            }
            if let code = attributes["currency"], let rate = attributes["rate"].flatMap(Double.init),
               code.count == 3, code.allSatisfy({ $0.isASCII && $0.isUppercase }), rate.isFinite, rate > 0 {
                rates[code] = rate
            }
        }

        /// "2026-11-10" as a date.
        private static func day(_ text: String) -> Date? {
            let parts = text.split(separator: "-").map { Int($0) }
            guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2] else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        }
    }
}

public extension UnitTable {
    /// The table with a unit for every currency of `rates`, known by its
    /// code, its sign and its name, in English and in the language of `locale`.
    func adding(_ rates: ExchangeRates, locale: Locale = .current) -> UnitTable {
        var table = self
        let english = Locale(identifier: "en_US")
        for (code, rate) in rates.perEuro.sorted(by: { $0.key < $1.key }) where rate > 0 {
            var names = Self.currencyNames[code] ?? []
            for locale in [english, locale] {
                if let name = locale.localizedString(forCurrencyCode: code) {
                    names += [name, name + "s"]
                }
            }
            // The euro is the base: a currency is worth as many as buy one.
            table.add(Unit(code, .currency, scale: 1 / rate), names: names)
        }
        return table
    }

    /// What a currency is called for short. A name that several share goes
    /// to the one most often meant by it.
    private static let currencyNames: [String: [String]] = [
        "USD": ["$", "dollar", "dollars", "bucks"],
        "EUR": ["€", "euro", "euros"],
        "GBP": ["£", "pound", "pounds", "quid", "sterling"],
        "JPY": ["¥", "yen"],
        "CHF": ["franc", "francs", "franken"],
        "CNY": ["yuan", "rmb", "renminbi"],
        "INR": ["₹", "rupee", "rupees"],
        "KRW": ["₩", "won"],
        "TRY": ["₺", "lira"],
        "PLN": ["zł", "zloty"],
        "ILS": ["₪", "shekel", "shekels"],
        "THB": ["฿", "baht"],
        "PHP": ["₱"],
        "MXN": ["peso", "pesos"],
        "ZAR": ["rand"],
        "SEK": ["krona"],
        "CZK": ["koruna"],
        "HUF": ["forint"],
        "IDR": ["rupiah"],
        "MYR": ["ringgit"],
    ]
}

/// The day's exchange rates, fetched now and then and kept on disk.
///
/// One file is asked for, the same for everyone, so nothing about what is
/// being converted leaves the Mac. What was kept is used until newer rates
/// have arrived, however old it is.
@MainActor
@Observable
public final class ExchangeRateStore {
    public var source: ExchangeRateSource {
        didSet {
            guard source != oldValue else { return }
            load()
            update()
        }
    }

    /// The rates in use. Nil while there are none, and when the source is off.
    public private(set) var rates: ExchangeRates?
    /// When the rates in use were fetched.
    public private(set) var fetched: Date?
    public private(set) var isUpdating = false
    /// Whether the last request went wrong. The rates in use are unchanged.
    public private(set) var failed = false

    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let fetch: Download.Fetch

    /// The bank sets its rates once on a working day, in the afternoon.
    static let lifetime: TimeInterval = 6 * 3600
    static let retryDelay: TimeInterval = 600

    public init(directory: URL, source: ExchangeRateSource = .ecb, fetch: @escaping Download.Fetch = Download.fetch) {
        self.directory = directory
        self.source = source
        self.fetch = fetch
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    /// Fetches the rates unless recent ones are kept.
    public func update(now: Date = .now) {
        if rates != nil, let fetched, now.timeIntervalSince(fetched) < Self.lifetime { return }
        if let retryAfter, now < retryAfter { return }
        refresh()
    }

    /// Fetches the rates, however recent the kept ones are.
    public func refresh() {
        guard !isUpdating, let url = source.url else { return }
        isUpdating = true
        Task { [fetch, source] in
            let answer = await Self.answer(of: fetch, url, from: source)
            finish(answer, from: source)
        }
    }

    // MARK: - Private

    private var file: URL {
        directory.appendingPathComponent(source.rawValue, isDirectory: false)
    }

    /// Reads what is kept for the source. The file's date is when it was fetched.
    private func load() {
        rates = nil
        fetched = nil
        failed = false
        retryAfter = nil
        guard source != .off, let data = try? Data(contentsOf: file), let kept = source.rates(in: data) else { return }
        rates = kept
        fetched = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private nonisolated static func answer(
        of fetch: Download.Fetch, _ url: URL, from source: ExchangeRateSource
    ) async -> (data: Data, rates: ExchangeRates)? {
        guard let answer = try? await fetch(url), answer.status == 200,
              let rates = source.rates(in: answer.data)
        else { return nil }
        return (answer.data, rates)
    }

    private func finish(_ answer: (data: Data, rates: ExchangeRates)?, from asked: ExchangeRateSource) {
        isUpdating = false
        // The source was changed while its answer was on the way.
        guard asked == source else {
            update()
            return
        }
        guard let answer else {
            failed = true
            retryAfter = Date.now.addingTimeInterval(Self.retryDelay)
            return
        }
        try? answer.data.write(to: file, options: .atomic)
        rates = answer.rates
        fetched = .now
        failed = false
        retryAfter = nil
    }
}
