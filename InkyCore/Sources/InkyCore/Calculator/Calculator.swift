import Foundation

/// The answer to a calculation.
public struct Calculation: Sendable, Equatable {
    /// The number of the answer, without its unit.
    public var value: Double
    public var unit: Unit?
    /// The answer as it is shown: "1,234.5 km".
    public var text: String
    /// The answer as it is copied, without grouping: "1234.5 km".
    public var plain: String
    /// Whether one currency was turned into another to get here.
    public var usesExchangeRates = false
}

/// Works out what is typed into the launcher.
///
/// Arithmetic: + - * / ^, parentheses, percent, factorial, `mod`, implicit
/// multiplication ("2pi", "3(4+1)"), functions and constants, and a few words
/// for them ("20% off 80", "2 power 10", "square root of 625").
///
/// Amounts with units, which add up and convert: "5 ft 10 in in cm",
/// "72 F to C", "100 usd in eur" where `units` has the currencies.
///
/// Whole numbers in other bases: "0xFF", "255 in hex".
public struct Calculator: Sendable {
    public var locale: Locale
    public var units: UnitTable

    public init(locale: Locale = .current, units: UnitTable = .standard) {
        self.locale = locale
        self.units = units
    }

    /// The answer to `input`, or nil if it is not a calculation. A number, a
    /// name or an amount on its own is deliberately not one, so searching for
    /// "1password", "pi" or "4k" does not turn up a calculator result.
    public func calculate(_ input: String) -> Calculation? {
        guard let tokens = Lexer(locale: locale).tokens(of: input) else { return nil }
        for reading in Parser.readings(of: tokens, units: units) where !reading.isTrivial {
            var evaluator = Evaluator()
            guard let value = evaluator.value(of: reading),
                  var calculation = calculation(for: value)
            else { continue }
            calculation.usesExchangeRates = evaluator.usedExchangeRates
            return calculation
        }
        return nil
    }

    /// The number `input` comes to, whatever its unit.
    public func evaluate(_ input: String) -> Double? {
        calculate(input)?.value
    }

    // MARK: - Formatting

    public func format(_ value: Double, grouping: Bool = true) -> String {
        format(value, fractionDigits: 10, grouping: grouping)
    }

    private func format(_ value: Double, fractionDigits: Int, grouping: Bool) -> String {
        // Never "-0".
        let value = value == 0 ? 0 : value
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.usesGroupingSeparator = grouping
        // A five rounds up, as it is taught. The default is to the even digit.
        formatter.roundingMode = .halfUp
        let magnitude = abs(value)
        if magnitude != 0, magnitude >= 1e15 || magnitude < 1e-9 {
            formatter.numberStyle = .scientific
            formatter.maximumSignificantDigits = 10
            formatter.exponentSymbol = "e"
        } else {
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = fractionDigits
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// An amount with its unit. A measurement is shown to about six digits,
    /// since the last ones of a conversion are noise.
    private func format(_ value: Double, in unit: Unit, grouping: Bool) -> String {
        if unit.dimension == .currency {
            return formatMoney(value, code: unit.symbol, grouping: grouping)
        }
        let magnitude = abs(value)
        let wholeDigits = magnitude > 0 ? Int(floor(log10(magnitude))) + 1 : 1
        let number = format(value, fractionDigits: min(12, max(2, 6 - wholeDigits)), grouping: grouping)
        // The degree of an angle sits right on its number.
        return unit.symbol == "°" ? number + unit.symbol : number + " " + unit.symbol
    }

    private func formatMoney(_ value: Double, code: String, grouping: Bool) -> String {
        let value = value == 0 ? 0 : value
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.roundingMode = .halfUp
        // Less than one of a currency is mostly a rate, and "0.01" says little.
        if value != 0, abs(value) < 1 {
            formatter.maximumFractionDigits = max(formatter.maximumFractionDigits, 4)
        }
        guard grouping else {
            // To be copied: the number, then the code.
            formatter.usesGroupingSeparator = false
            formatter.currencySymbol = ""
            let number = (formatter.string(from: NSNumber(value: value)) ?? String(value))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return number + " " + code
        }
        return formatter.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
    }

    private func formatTimespan(_ seconds: Double) -> String {
        // To the millisecond, so parts do not come out as "59.9999 s".
        var rest = (abs(seconds) * 1000).rounded() / 1000
        var parts: [String] = []
        for (symbol, length) in [("d", 86_400.0), ("h", 3600), ("min", 60)] {
            let count = (rest / length).rounded(.down)
            rest -= count * length
            if count > 0 {
                parts.append(format(count, fractionDigits: 0, grouping: true) + " " + symbol)
            }
        }
        if rest > 0 || parts.isEmpty {
            parts.append(format(rest, fractionDigits: 3, grouping: false) + " s")
        }
        return (seconds < 0 ? "-" : "") + parts.joined(separator: " ")
    }

    private func calculation(for value: Value) -> Calculation? {
        switch value {
        case .number(let number):
            guard number.isFinite else { return nil }
            return Calculation(value: number, text: format(number), plain: format(number, grouping: false))
        case .percent(let percent):
            return calculation(for: .number(percent / 100))
        case .quantity(let amount, let units):
            guard amount.isFinite, let unit = units.first else { return nil }
            return Calculation(
                value: amount,
                unit: unit,
                text: format(amount, in: unit, grouping: true),
                plain: format(amount, in: unit, grouping: false)
            )
        case .integer(let magnitude, let isNegative, let radix):
            let sign = isNegative ? "-" : ""
            let value = (isNegative ? -1 : 1) * Double(magnitude)
            if radix == 10 {
                let grouped = magnitude.formatted(IntegerFormatStyle<UInt64>.number.locale(locale))
                return Calculation(value: value, text: sign + grouped, plain: sign + String(magnitude))
            }
            let prefix = [2: "0b", 8: "0o", 16: "0x"][radix] ?? ""
            let text = sign + prefix + String(magnitude, radix: radix, uppercase: true)
            return Calculation(value: value, text: text, plain: text)
        case .timespan(let seconds):
            guard seconds.isFinite else { return nil }
            let text = formatTimespan(seconds)
            return Calculation(value: seconds, text: text, plain: text)
        }
    }
}

// MARK: - Working it out

/// What an expression comes to.
private enum Value {
    case number(Double)
    /// Not yet divided by a hundred: "80 + 20%" needs to know it is one.
    case percent(Double)
    /// An amount in the first of `units`. The others are what its name could
    /// also have meant, until something it is used with settles it.
    case quantity(Double, [Unit])
    /// A whole number to be written in `radix`.
    case integer(UInt64, isNegative: Bool, radix: Int)
    /// A time in seconds, to be written out in parts.
    case timespan(Double)
}

private struct Evaluator {
    private(set) var usedExchangeRates = false

    mutating func value(of expression: Expression) -> Value? {
        switch expression {
        case .number(let number, _, _):
            return .number(number)
        case .constant(let constant):
            return .number(constant)
        case .quantity(let amount, let units):
            guard let number = value(of: amount).flatMap(Self.number) else { return nil }
            return .quantity(number, units)
        case .percent(let amount):
            guard case .number(let number)? = value(of: amount) else { return nil }
            return .percent(number)
        case .negate(let operand):
            switch value(of: operand) {
            case .number(let number)?: return .number(-number)
            case .percent(let percent)?: return .percent(-percent)
            case .quantity(let amount, let units)?: return .quantity(-amount, units)
            default: return nil
            }
        case .factorial(let operand):
            guard case .number(let number)? = value(of: operand),
                  number >= 0, number <= 170, number == number.rounded()
            else { return nil }
            return .number((1...max(1, Int(number))).reduce(1.0) { $0 * Double($1) })
        case .binary(let operation, let left, let right):
            guard let left = value(of: left), let right = value(of: right) else { return nil }
            return apply(operation, left, right)
        case .call(let function, let argument):
            return value(of: argument).flatMap { call(function, $0) }
        case .convert(let source, let target):
            return convert(source, to: target)
        }
    }

    /// A value that is only a number. A percentage counts as its fraction.
    private static func number(_ value: Value) -> Double? {
        switch value {
        case .number(let number): number
        case .percent(let percent): percent / 100
        default: nil
        }
    }

    // MARK: - Operators

    private mutating func apply(_ operation: Expression.Operator, _ left: Value, _ right: Value) -> Value? {
        switch operation {
        case .add: return add(left, right, sign: 1)
        case .subtract: return add(left, right, sign: -1)
        case .multiply: return multiply(left, right)
        case .divide: return divide(left, right)
        case .modulo:
            switch (left, Self.number(right)) {
            case (.quantity(let amount, let units), let divisor?):
                return .quantity(amount.truncatingRemainder(dividingBy: divisor), units)
            case (_, let divisor?):
                return Self.number(left).map { .number($0.truncatingRemainder(dividingBy: divisor)) }
            default:
                return nil
            }
        case .power:
            guard let base = Self.number(left), let exponent = Self.number(right) else { return nil }
            return .number(pow(base, exponent))
        }
    }

    private mutating func add(_ left: Value, _ right: Value, sign: Double) -> Value? {
        switch (left, right) {
        case (.number(let a), .number(let b)):
            return .number(a + sign * b)
        // "80 + 20%" is 80 and a fifth of it.
        case (.number(let a), .percent(let percent)):
            return .number(a * (1 + sign * percent / 100))
        case (.quantity(let a, let units), .percent(let percent)):
            return .quantity(a * (1 + sign * percent / 100), units)
        case (.percent(let a), .percent(let b)):
            return .percent(a + sign * b)
        case (.percent(let a), .number(let b)):
            return .number(a / 100 + sign * b)
        case (.quantity(let a, let units), .quantity(let b, let others)):
            // The answer is in the unit that was named first.
            guard let (unit, other) = Self.pair(units, others) else { return nil }
            return .quantity(a + sign * convert(b, from: other, to: unit), [unit])
        // A bare number next to an amount is of the same unit: "$100 + 20".
        case (.quantity(let a, let units), .number(let b)):
            return .quantity(a + sign * b, units)
        case (.number(let a), .quantity(let b, let units)):
            return .quantity(a + sign * b, units)
        default:
            return nil
        }
    }

    private func multiply(_ left: Value, _ right: Value) -> Value? {
        switch (left, right) {
        case (.quantity(let amount, let units), let factor), (let factor, .quantity(let amount, let units)):
            // Two amounts would make an area, or something without a name.
            return Self.number(factor).map { .quantity(amount * $0, units) }
        default:
            guard let a = Self.number(left), let b = Self.number(right) else { return nil }
            return .number(a * b)
        }
    }

    private func divide(_ left: Value, _ right: Value) -> Value? {
        switch (left, right) {
        case (.quantity(let a, let units), .quantity(let b, let others)):
            // How many times one goes into the other. Temperatures have no
            // such thing: 20 °C is not twice 10 °C.
            guard let (unit, other) = Self.pair(units, others), unit.offset == 0, other.offset == 0 else { return nil }
            return .number(a * unit.scale / (b * other.scale))
        case (.quantity(let amount, let units), let divisor):
            return Self.number(divisor).map { .quantity(amount / $0, units) }
        default:
            guard let a = Self.number(left), let b = Self.number(right) else { return nil }
            return .number(a / b)
        }
    }

    private func call(_ function: Function, _ argument: Value) -> Value? {
        guard case .quantity(let amount, let units) = argument else {
            return Self.number(argument).map { .number(function.apply($0)) }
        }
        switch function.kind {
        case .trigonometric:
            guard let angle = units.first(where: { $0.dimension == .angle }) else { return nil }
            return .number(function.apply(angle.toBase(amount)))
        case .rounding:
            return .quantity(function.apply(amount), units)
        case .plain:
            return nil
        }
    }

    // MARK: - Conversions

    private mutating func convert(_ source: Expression, to target: Expression.Target) -> Value? {
        switch target {
        case .unit(let targets):
            guard case .quantity(let amount, let units)? = value(of: source),
                  let (unit, target) = Self.pair(units, targets)
            else { return nil }
            return .quantity(convert(amount, from: unit, to: target), [target])
        case .timespan:
            guard case .quantity(let amount, let units)? = value(of: source),
                  let unit = units.first(where: { $0.dimension == .duration })
            else { return nil }
            return .timespan(unit.toBase(amount))
        case .base(let radix):
            // A number as it was typed is exact however large. Anything
            // worked out is a double, exact to 2^53.
            if case .number(_, let integer?, _) = source {
                return .integer(integer, isNegative: false, radix: radix)
            }
            switch value(of: source) {
            case .integer(let magnitude, let isNegative, _)?:
                return .integer(magnitude, isNegative: isNegative, radix: radix)
            case .number(let number)?:
                guard number == number.rounded(), abs(number) <= 9_007_199_254_740_992 else { return nil }
                return .integer(UInt64(abs(number)), isNegative: number < 0, radix: radix)
            default:
                return nil
            }
        }
    }

    private mutating func convert(_ amount: Double, from unit: Unit, to target: Unit) -> Double {
        guard unit != target else { return amount }
        if unit.dimension == .currency { usedExchangeRates = true }
        return target.fromBase(unit.toBase(amount))
    }

    /// The first unit of each list that measure the same thing: for "8 oz"
    /// and "ml", the fluid ounce and the milliliter.
    private static func pair(_ units: [Unit], _ others: [Unit]) -> (Unit, Unit)? {
        for unit in units {
            if let other = others.first(where: { $0.dimension == unit.dimension }) {
                return (unit, other)
            }
        }
        return nil
    }
}
