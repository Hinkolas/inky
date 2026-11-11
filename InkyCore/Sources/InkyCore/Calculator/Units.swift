import Foundation

/// What a unit measures. Only units of the same dimension convert into each
/// other.
public enum Dimension: String, Sendable, Hashable {
    case length, mass, duration, temperature, area, volume, speed, data
    case angle, energy, power, pressure, frequency, currency
    /// Lengths on a web page, which are counted in pixels.
    case screen
}

public struct Unit: Sendable, Hashable {
    /// How it is written after a number, such as "km". For a currency, its
    /// code.
    public let symbol: String
    public let dimension: Dimension
    /// How many of its dimension's base unit one of it is.
    let scale: Double
    /// Added after scaling. Only temperatures have one: 0 °C is 273.15 K.
    let offset: Double

    init(_ symbol: String, _ dimension: Dimension, scale: Double, offset: Double = 0) {
        self.symbol = symbol
        self.dimension = dimension
        self.scale = scale
        self.offset = offset
    }

    func toBase(_ value: Double) -> Double {
        value * scale + offset
    }

    func fromBase(_ value: Double) -> Double {
        (value - offset) / scale
    }
}

/// The units a calculation may name.
///
/// A name is one or more tokens: "km", "fl oz", "km/h", "m2". The same name
/// may belong to several units, as "oz" is a weight and a volume. They are
/// kept in the order they were added, and what the name is used with decides
/// between them.
public struct UnitTable: Sendable {
    struct Match {
        var units: [Unit]
        /// How many tokens the name took.
        var count: Int
        /// Whether it was typed in the unit's own case. "Mb" is megabits;
        /// "mb" is only taken to be megabytes.
        var isExact: Bool
    }

    private var exact: [String: [Unit]] = [:]
    private var folded: [String: [Unit]] = [:]
    private var longest = 1

    public init() {}

    /// Makes `unit` known by its symbol and by `names`.
    mutating func add(_ unit: Unit, names: [String] = []) {
        for name in [unit.symbol] + names {
            // A name is split the way input is, so it is found the way it is typed.
            // A name that cannot be typed, such as one with a full stop, is left out.
            guard let tokens = Self.lexer.tokens(of: name), !tokens.isEmpty else { continue }
            let key = tokens.map(\.text).joined(separator: " ")
            longest = max(longest, tokens.count)
            if exact[key]?.contains(unit) != true {
                exact[key, default: []].append(unit)
            }
            if folded[key.lowercased()]?.contains(unit) != true {
                folded[key.lowercased(), default: []].append(unit)
            }
        }
    }

    /// The longest unit name that starts at `index` and ends before `end`.
    func match(_ tokens: [Token], at index: Int, before end: Int) -> Match? {
        guard index < end, !tokens[index].isNumber else { return nil }
        var keys: [String] = []
        for offset in 0..<min(longest, end - index) {
            let token = tokens[index + offset]
            // The 2 of "m2" belongs to the name only where it touches it.
            if token.isNumber, !token.isAttached { break }
            keys.append(offset == 0 ? token.text : keys[offset - 1] + " " + token.text)
        }
        for (offset, key) in keys.enumerated().reversed() {
            if let units = exact[key] {
                return Match(units: units, count: offset + 1, isExact: true)
            }
            if let units = folded[key.lowercased()] {
                return Match(units: units, count: offset + 1, isExact: false)
            }
        }
        return nil
    }

    private static let lexer = Lexer(locale: Locale(identifier: "en_US_POSIX"))
}

// MARK: - The units that never change

public extension UnitTable {
    /// Every unit but the currencies, which depend on the day's rates.
    static let standard: UnitTable = {
        var table = UnitTable()

        func add(_ symbol: String, _ dimension: Dimension, _ scale: Double, offset: Double = 0, _ names: [String] = []) {
            assert(([symbol] + names).allSatisfy { UnitTable.lexer.tokens(of: $0)?.isEmpty == false }, "\(symbol) has a name that cannot be typed")
            table.add(Unit(symbol, dimension, scale: scale, offset: offset), names: names)
        }

        /// The unit with each of `prefixes` in front: "km", "kilometer".
        func family(_ symbol: String, _ words: [String], _ dimension: Dimension, _ scale: Double, _ prefixes: String) {
            for prefix in prefixes {
                guard let (name, factor) = siPrefixes[prefix] else { continue }
                var names = plural(words.map { name + $0 })
                if prefix == "µ" {
                    // The micro sign is hard to type, and has a Greek twin.
                    names += ["u" + symbol, "μ" + symbol]
                }
                add(String(prefix) + symbol, dimension, scale * factor, names)
            }
        }

        /// More names for a unit that is already there.
        func alias(_ symbol: String, _ names: [String]) {
            guard let unit = table.exact[symbol]?.first else {
                assertionFailure("No unit “\(symbol)” to name")
                return
            }
            table.add(unit, names: names)
        }

        // Length, in meters.
        add("m", .length, 1, plural(["meter", "metre"]))
        family("m", ["meter", "metre"], .length, 1, "kcdmµn")
        alias("µm", plural(["micron"]))
        add("in", .length, 0.0254, ["inch", "inches", "\""])
        add("ft", .length, 0.3048, ["foot", "feet", "'"])
        add("yd", .length, 0.9144, ["yds"] + plural(["yard"]))
        add("mi", .length, 1609.344, plural(["mile"]))
        add("nmi", .length, 1852, plural(["nautical mile"]))
        add("ly", .length, 9.4607304725808e15, plural(["light year", "lightyear"]))
        add("au", .length, 149_597_870_700, plural(["astronomical unit"]))

        // Mass, in kilograms.
        add("g", .mass, 1e-3, plural(["gram", "gramme"]))
        family("g", ["gram", "gramme"], .mass, 1e-3, "kmµ")
        alias("kg", plural(["kilo"]))
        alias("µg", ["mcg"])
        add("t", .mass, 1000, plural(["tonne", "ton", "metric ton"]))
        add("oz", .mass, 0.028349523125, plural(["ounce"]))
        add("lb", .mass, 0.45359237, ["lbs"] + plural(["pound"]))
        add("st", .mass, 6.35029318, plural(["stone"]))
        add("ct", .mass, 0.0002, plural(["carat"]))

        // Time, in seconds. A month and a year are the average ones.
        add("s", .duration, 1, ["sec", "secs"] + plural(["second"]))
        family("s", ["second"], .duration, 1, "mµn")
        add("min", .duration, 60, ["mins"] + plural(["minute"]))
        add("h", .duration, 3600, ["hr", "hrs"] + plural(["hour"]))
        add("d", .duration, 86_400, plural(["day"]))
        add("wk", .duration, 604_800, ["wks"] + plural(["week"]))
        add("mo", .duration, 2_629_746, ["mos"] + plural(["month"]))
        add("yr", .duration, 31_556_952, ["y", "yrs"] + plural(["year"]))
        // After the meter, so "m" is a minute only next to another time: "1h 30m".
        alias("min", ["m"])

        // Temperature, in kelvins.
        add("K", .temperature, 1, plural(["kelvin"]))
        add("°C", .temperature, 1, offset: 273.15, [
            "C", "celsius", "centigrade", "degC", "deg C", "degree celsius", "degrees celsius", "degrees C",
        ])
        add("°F", .temperature, 5 / 9, offset: 459.67 * 5 / 9, [
            "F", "fahrenheit", "degF", "deg F", "degree fahrenheit", "degrees fahrenheit", "degrees F",
        ])

        // Area, in square meters.
        add("m²", .area, 1, ["m2", "m^2", "sqm", "sq m"] + plural(["square meter", "square metre"]))
        add("km²", .area, 1e6, ["km2", "km^2", "sq km"] + plural(["square kilometer", "square kilometre"]))
        add("cm²", .area, 1e-4, ["cm2", "cm^2", "sq cm"] + plural(["square centimeter", "square centimetre"]))
        add("mm²", .area, 1e-6, ["mm2", "mm^2", "sq mm"] + plural(["square millimeter", "square millimetre"]))
        add("ha", .area, 1e4, plural(["hectare"]))
        add("ac", .area, 4046.8564224, plural(["acre"]))
        add("ft²", .area, 0.09290304, ["ft2", "ft^2", "sq ft", "sqft", "square foot", "square feet"])
        add("in²", .area, 0.00064516, ["in2", "in^2", "sq in", "square inch", "square inches"])
        add("yd²", .area, 0.83612736, ["yd2", "yd^2", "sq yd"] + plural(["square yard"]))
        add("mi²", .area, 2_589_988.110336, ["mi2", "mi^2", "sq mi"] + plural(["square mile"]))

        // Volume, in liters. Spoons, cups, pints and gallons are the US ones.
        add("l", .volume, 1, ["L"] + plural(["liter", "litre"]))
        family("l", ["liter", "litre"], .volume, 1, "mcdh")
        add("m³", .volume, 1000, ["m3", "m^3", "cbm"] + plural(["cubic meter", "cubic metre"]))
        add("cm³", .volume, 0.001, ["cm3", "cm^3", "cc"] + plural(["cubic centimeter", "cubic centimetre"]))
        add("in³", .volume, 0.016387064, ["in3", "in^3", "cu in", "cubic inch", "cubic inches"])
        add("ft³", .volume, 28.316846592, ["ft3", "ft^3", "cu ft", "cubic foot", "cubic feet"])
        add("tsp", .volume, 0.00492892159375, plural(["teaspoon"]))
        add("tbsp", .volume, 0.01478676478125, plural(["tablespoon"]))
        // After the ounce of weight, so "oz" is a volume only when asked for one.
        add("fl oz", .volume, 0.0295735295625, ["floz", "oz"] + plural(["fluid ounce"]))
        add("cup", .volume, 0.2365882365, ["cups"])
        add("pt", .volume, 0.473176473, plural(["pint"]))
        add("qt", .volume, 0.946352946, plural(["quart"]))
        add("gal", .volume, 3.785411784, plural(["gallon"]))
        add("imp pt", .volume, 0.56826125, plural(["imperial pint", "uk pint"]))
        add("imp gal", .volume, 4.54609, plural(["imperial gallon", "uk gallon"]))

        // Speed, in meters per second.
        add("m/s", .speed, 1, ["mps", "meter per second", "meters per second", "metres per second"])
        add("km/h", .speed, 1 / 3.6, [
            "kmh", "kph", "kmph", "km/hr", "kilometer per hour", "kilometers per hour", "kilometres per hour",
        ])
        add("mph", .speed, 0.44704, ["mi/h", "mile per hour", "miles per hour"])
        add("kn", .speed, 1852 / 3600, ["kt", "kts"] + plural(["knot"]))
        add("ft/s", .speed, 0.3048, ["foot per second", "feet per second"])

        // Data, in bytes, a thousand to the next. Bytes come before bits, so
        // "mb" in lowercase is megabytes.
        add("B", .data, 1, plural(["byte"]))
        add("kB", .data, 1e3, ["KB"] + plural(["kilobyte"]))
        add("MB", .data, 1e6, plural(["megabyte"]))
        add("GB", .data, 1e9, plural(["gigabyte"]))
        add("TB", .data, 1e12, plural(["terabyte"]))
        add("PB", .data, 1e15, plural(["petabyte"]))
        add("KiB", .data, 1024, plural(["kibibyte"]))
        add("MiB", .data, 1_048_576, plural(["mebibyte"]))
        add("GiB", .data, 1_073_741_824, plural(["gibibyte"]))
        add("TiB", .data, 1_099_511_627_776, plural(["tebibyte"]))
        add("PiB", .data, 1_125_899_906_842_624, plural(["pebibyte"]))
        add("bit", .data, 0.125, ["b", "bits"])
        add("kbit", .data, 125, ["Kb", "kbits"] + plural(["kilobit"]))
        add("Mbit", .data, 125e3, ["Mb", "Mbits"] + plural(["megabit"]))
        add("Gbit", .data, 125e6, ["Gb", "Gbits"] + plural(["gigabit"]))

        // Angle, in radians.
        add("rad", .angle, 1, plural(["radian"]))
        add("°", .angle, .pi / 180, ["deg"] + plural(["degree"]))
        add("gon", .angle, .pi / 200, ["grad", "grads"] + plural(["gradian"]))
        add("turn", .angle, 2 * .pi, ["turns", "rev", "revs"] + plural(["revolution"]))

        // Energy, in joules.
        add("J", .energy, 1, plural(["joule"]))
        family("J", ["joule"], .energy, 1, "kM")
        add("cal", .energy, 4.184, plural(["calorie"]))
        add("kcal", .energy, 4184, plural(["kilocalorie"]))
        add("Wh", .energy, 3600, plural(["watt hour"]))
        family("Wh", ["watt hour"], .energy, 3600, "kMG")
        add("eV", .energy, 1.602176634e-19, plural(["electronvolt"]))
        add("BTU", .energy, 1055.05585262)

        // Power, in watts. Larger ones first, so "mw" is megawatts.
        add("W", .power, 1, plural(["watt"]))
        family("W", ["watt"], .power, 1, "GMkm")
        add("hp", .power, 745.69987158227022, ["horsepower"])
        add("PS", .power, 735.49875)

        // Pressure, in pascals.
        add("Pa", .pressure, 1, plural(["pascal"]))
        family("Pa", ["pascal"], .pressure, 1, "Mkh")
        add("bar", .pressure, 1e5, ["bars"])
        add("mbar", .pressure, 100, plural(["millibar"]))
        add("psi", .pressure, 6894.757293168)
        add("atm", .pressure, 101_325, plural(["atmosphere"]))
        add("mmHg", .pressure, 133.322387415)
        add("torr", .pressure, 101_325 / 760)

        // Frequency, in hertz.
        add("Hz", .frequency, 1, ["hertz"])
        family("Hz", ["hertz"], .frequency, 1, "GMk")
        add("rpm", .frequency, 1 / 60)

        return table
    }()

    /// The table with the lengths of a web page: the pixel, and the rem and
    /// the em, each `pixelsPerRem` pixels. That is the size of a page's text,
    /// 16 unless the page says otherwise, and an em is taken to be as large.
    ///
    /// A pixel is not a length that can be measured, so none of them convert
    /// into inches or centimeters.
    func adding(pixelsPerRem: Double) -> UnitTable {
        var table = self
        table.add(Unit("px", .screen, scale: 1), names: ["pixel", "pixels"])
        guard pixelsPerRem.isFinite, pixelsPerRem > 0 else { return table }
        table.add(Unit("rem", .screen, scale: pixelsPerRem), names: ["rems"])
        table.add(Unit("em", .screen, scale: pixelsPerRem), names: ["ems"])
        return table
    }

    private static let siPrefixes: [Character: (name: String, factor: Double)] = [
        "n": ("nano", 1e-9), "µ": ("micro", 1e-6), "m": ("milli", 1e-3), "c": ("centi", 1e-2),
        "d": ("deci", 1e-1), "h": ("hecto", 1e2), "k": ("kilo", 1e3), "M": ("mega", 1e6), "G": ("giga", 1e9),
    ]

    private static func plural(_ words: [String]) -> [String] {
        words.flatMap { [$0, $0 + "s"] }
    }
}
