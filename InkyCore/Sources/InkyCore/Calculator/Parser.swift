import Foundation

/// What a calculation says, before anything is worked out.
indirect enum Expression: Sendable {
    enum Operator: Sendable {
        case add, subtract, multiply, divide, modulo, power
    }

    /// What a result is asked to be shown as.
    enum Target: Sendable {
        /// Every unit the name could mean.
        case unit([Unit])
        case base(Int)
        /// A time broken down into days, hours, minutes and seconds.
        case timespan
    }

    case number(Double, integer: UInt64?, radix: Int)
    case constant(Double)
    /// A value with a unit. The name may belong to several units.
    case quantity(Expression, [Unit])
    case percent(Expression)
    case negate(Expression)
    case factorial(Expression)
    case binary(Operator, Expression, Expression)
    case call(Function, Expression)
    case convert(Expression, Target)

    /// Whether nothing is worked out: a number, a constant or an amount on
    /// its own. Those are searches, such as "42", "pi" or "4k", not sums.
    var isTrivial: Bool {
        switch self {
        case .number(_, _, let radix): radix == 10
        case .constant: true
        case .quantity(let value, _), .negate(let value): value.isTrivial
        default: false
        }
    }
}

struct Function: Sendable {
    enum Kind: Sendable {
        case plain
        /// Takes an angle, in radians unless it has a unit.
        case trigonometric
        /// Keeps the unit of what it is given.
        case rounding
    }

    var kind: Kind
    var apply: @Sendable (Double) -> Double

    static let named: [String: Function] = {
        var functions: [String: Function] = [:]
        func add(_ kind: Kind, _ entries: [String: @Sendable (Double) -> Double]) {
            for (name, apply) in entries {
                functions[name] = Function(kind: kind, apply: apply)
            }
        }
        add(.plain, [
            "sqrt": { $0.squareRoot() }, "cbrt": { cbrt($0) }, "exp": { exp($0) },
            "ln": { log($0) }, "log": { log10($0) }, "log10": { log10($0) }, "log2": { log2($0) },
            "asin": { asin($0) }, "acos": { acos($0) }, "atan": { atan($0) },
            "sinh": { sinh($0) }, "cosh": { cosh($0) }, "tanh": { tanh($0) },
            "asinh": { asinh($0) }, "acosh": { acosh($0) }, "atanh": { atanh($0) },
        ])
        add(.trigonometric, [
            "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
            "cot": { 1 / tan($0) }, "sec": { 1 / cos($0) }, "csc": { 1 / sin($0) },
        ])
        add(.rounding, [
            "abs": { abs($0) }, "round": { $0.rounded() }, "floor": { floor($0) }, "ceil": { ceil($0) },
        ])
        return functions
    }()

    /// Functions that are spelled out: "square root of 625".
    static let phrases: [(words: [String], function: String)] = [
        (["square", "root"], "sqrt"), (["cube", "root"], "cbrt"), (["cubic", "root"], "cbrt"),
    ]
}

/// Turns tokens into expressions.
///
/// A recursive descent parser, one method per level of precedence. It reads
/// strictly: tokens it cannot place make the input not a calculation.
struct Parser {
    private let tokens: [Token]
    private let units: UnitTable
    /// How many parentheses are open at each token.
    private let depths: [Int]

    private var position = 0
    private var end = 0
    /// Off inside an exponent, so the unit in "2^10 MB" belongs to the power.
    private var allowsUnits = true
    /// How many values are being read inside one another. The parser calls
    /// itself for each, and input such as two hundred opening parentheses
    /// would otherwise run it out of stack.
    private var nesting = 0
    private static let deepestNesting = 48

    /// Every way to read `tokens`, the likeliest first. Whether a reading
    /// makes sense shows only when it is worked out: "8 oz in ml" needs "oz"
    /// to be a volume.
    static func readings(of tokens: [Token], units: UnitTable) -> [Expression] {
        var tokens = tokens
        // "2 + 2 =" asks the same as "2 + 2".
        if tokens.last?.isSymbol("=") == true { tokens.removeLast() }
        guard !tokens.isEmpty else { return [] }

        var depths: [Int] = []
        var depth = 0
        for token in tokens {
            if token.isSymbol(")") { depth -= 1 }
            depths.append(depth)
            if token.isSymbol("(") { depth += 1 }
        }

        let parser = Parser(tokens: tokens, units: units, depths: depths)
        return parser.readings(in: 0..<tokens.count).map { reading in
            // A number written in another base is asked for in decimal.
            if case .number(_, _, let radix) = reading, radix != 10 {
                return .convert(reading, .base(10))
            }
            return reading
        }
    }

    private init(tokens: [Token], units: UnitTable, depths: [Int]) {
        self.tokens = tokens
        self.units = units
        self.depths = depths
    }

    // MARK: - Conversions

    /// "10 in in cm" has two words that may ask for a conversion, and only the
    /// second does. Each is tried, the last first: what follows it must name
    /// a target, and what precedes it must be readable too.
    private func readings(in range: Range<Int>) -> [Expression] {
        var found: [Expression] = []
        let splits = range.dropFirst().dropLast().filter { depths[$0] == 0 && Self.isConversion(tokens[$0]) }
        // Each one doubles the readings. More than a few is not a calculation.
        if splits.count <= 4 {
            for split in splits.reversed() {
                guard let target = target(in: (split + 1)..<range.upperBound) else { continue }
                found += sources(in: range.lowerBound..<split).map { .convert($0, target) }
            }
        }
        if let expression = expression(in: range) {
            found.append(expression)
        }
        return found
    }

    /// What can be converted: a calculation, or a unit on its own, which is
    /// one of it: "usd in eur".
    private func sources(in range: Range<Int>) -> [Expression] {
        var found = readings(in: range)
        if let match = units.match(tokens, at: range.lowerBound, before: range.upperBound), match.count == range.count {
            found.append(.quantity(.number(1, integer: 1, radix: 10), match.units))
        }
        return found
    }

    private func target(in range: Range<Int>) -> Expression.Target? {
        if range.count == 1, let word = tokens[range.lowerBound].word {
            if let radix = Self.bases[word] { return .base(radix) }
            if word == "timespan" { return .timespan }
        }
        if let match = units.match(tokens, at: range.lowerBound, before: range.upperBound), match.count == range.count {
            return .unit(match.units)
        }
        return nil
    }

    private func expression(in range: Range<Int>) -> Expression? {
        var parser = self
        parser.position = range.lowerBound
        parser.end = range.upperBound
        guard let expression = parser.sum(), parser.position == parser.end else { return nil }
        return expression
    }

    private static func isConversion(_ token: Token) -> Bool {
        token.isSymbol("→") || token.word.map(conversions.contains) == true
    }

    private static let conversions: Set<String> = ["in", "to", "as", "into"]
    private static let bases: [String: Int] = [
        "hex": 16, "hexadecimal": 16, "dec": 10, "decimal": 10, "oct": 8, "octal": 8, "bin": 2, "binary": 2,
    ]

    // MARK: - Tokens

    private var peek: Token? {
        position < end ? tokens[position] : nil
    }

    private mutating func take(sign symbol: Character) -> Bool {
        guard peek?.isSymbol(symbol) == true else { return false }
        position += 1
        return true
    }

    /// Takes `words` if they come next, in this order.
    private mutating func take(_ words: String...) -> Bool {
        guard position + words.count <= end,
              zip(words, tokens[position...]).allSatisfy({ $0 == $1.word })
        else { return false }
        position += words.count
        return true
    }

    // MARK: - Precedence, lowest first

    private mutating func sum() -> Expression? {
        guard var value = product() else { return nil }
        while true {
            let operation: Expression.Operator
            if take(sign: "+") || take("plus") {
                operation = .add
            } else if take(sign: "-") || take("minus") {
                operation = .subtract
            } else {
                return value
            }
            guard let other = product() else { return nil }
            value = .binary(operation, value, other)
        }
    }

    private mutating func product() -> Expression? {
        guard var value = unary() else { return nil }
        while true {
            if take(sign: "*") || take("times") || take("x") || take("multiplied", "by") || take("of") {
                guard let other = unary() else { return nil }
                value = .binary(.multiply, value, other)
            } else if take(sign: "/") || take("divided", "by") {
                guard let other = unary() else { return nil }
                value = Self.divide(value, by: other)
            } else if take("mod") {
                guard let other = unary() else { return nil }
                value = .binary(.modulo, value, other)
            } else if case .percent = value, take("off") {
                // "20% off 80" is 80 less 20%.
                guard let other = unary() else { return nil }
                value = .binary(.subtract, other, value)
            } else if case .percent = value, take("on") {
                guard let other = unary() else { return nil }
                value = .binary(.add, other, value)
            } else if Self.isAmount(value), peek?.isNumber == true {
                // Amounts in a row add up: "5 ft 10 in", "1h 30m 20s".
                guard let other = postfix(), case .quantity = other else { return nil }
                value = .binary(.add, value, other)
            } else if startsFactor {
                // Implicit multiplication: "2pi", "3(4+1)", "2 sqrt(9)".
                guard let other = power() else { return nil }
                value = .binary(.multiply, value, other)
            } else {
                return value
            }
        }
    }

    /// Whether it is an amount with a unit, or several of them added up.
    private static func isAmount(_ value: Expression) -> Bool {
        switch value {
        case .quantity: true
        case .binary(.add, _, .quantity): true
        default: false
        }
    }

    /// "1/2 inch" is half an inch. One divided by two inches is nothing.
    private static func divide(_ value: Expression, by other: Expression) -> Expression {
        if case .number = value, case .quantity(let amount, let units) = other, case .number = amount {
            return .quantity(.binary(.divide, value, amount), units)
        }
        return .binary(.divide, value, other)
    }

    /// Whether what comes next can be multiplied with what came before it
    /// without a sign in between.
    private var startsFactor: Bool {
        guard let token = peek else { return false }
        if token.isSymbol("(") || token.isSymbol("√") { return true }
        guard let word = token.word else { return false }
        return Function.named[word] != nil || Self.constants[word] != nil
            || Function.phrases.contains { $0.words[0] == word }
    }

    private mutating func unary() -> Expression? {
        nesting += 1
        defer { nesting -= 1 }
        guard nesting <= Self.deepestNesting else { return nil }

        if take(sign: "-") { return unary().map { .negate($0) } }
        if take(sign: "+") { return unary() }
        return power()
    }

    private mutating func power() -> Expression? {
        guard let base = postfix() else { return nil }
        guard take(sign: "^") || take("power") || take("to", "the", "power", "of") else { return base }

        let allowedUnits = allowsUnits
        allowsUnits = false
        let exponent = unary()
        allowsUnits = allowedUnits
        guard let exponent else { return nil }

        var value = Expression.binary(.power, base, exponent)
        while let next = suffix(of: value) { value = next }
        return value
    }

    private mutating func postfix() -> Expression? {
        guard var value = primary() else { return nil }
        while let next = suffix(of: value) { value = next }
        return value
    }

    /// What follows a value and belongs to it: a percent sign, a unit, "k".
    private mutating func suffix(of value: Expression) -> Expression? {
        if take(sign: "%") { return .percent(value) }
        if take(sign: "!") { return .factorial(value) }
        if take("squared") { return .binary(.power, value, .number(2, integer: 2, radix: 10)) }
        if take("cubed") { return .binary(.power, value, .number(3, integer: 3, radix: 10)) }

        guard allowsUnits else { return nil }
        if case .quantity = value { return nil }

        // Typed in its own case, a name is the unit: "K" is kelvin, and "k" a
        // thousand. Only then is a name read loosely.
        let match = units.match(tokens, at: position, before: end)
        if let match, match.isExact {
            position += match.count
            return .quantity(value, match.units)
        }
        if let factor = peek.flatMap({ $0.isWord ? Self.exactMultipliers[$0.text] : nil }) {
            position += 1
            return Self.scale(value, by: factor)
        }
        if let match, !(match.count == 1 && isName(tokens[position])) {
            position += match.count
            return .quantity(value, match.units)
        }
        if let factor = peek?.word.flatMap({ Self.multipliers[$0] }) {
            position += 1
            return Self.scale(value, by: factor)
        }
        return nil
    }

    /// Whether the word is a function or a constant, which no unit may hide.
    private func isName(_ token: Token) -> Bool {
        guard let word = token.word else { return false }
        return Function.named[word] != nil || Self.constants[word] != nil
    }

    /// "10k" is a number as much as "10000" is, so it stays one.
    private static func scale(_ value: Expression, by factor: Double) -> Expression {
        if case .number(let number, _, 10) = value {
            return .number(number * factor, integer: nil, radix: 10)
        }
        return .binary(.multiply, value, .number(factor, integer: nil, radix: 10))
    }

    private mutating func primary() -> Expression? {
        nesting += 1
        defer { nesting -= 1 }
        guard nesting <= Self.deepestNesting, let token = peek else { return nil }
        switch token.kind {
        case .number(let value, let integer, let radix):
            position += 1
            return .number(value, integer: integer, radix: radix)
        case .symbol("("):
            position += 1
            return parenthesized()
        case .symbol("√"):
            position += 1
            guard let argument = power(), let root = Function.named["sqrt"] else { return nil }
            return .call(root, argument)
        case .word:
            return named()
        default:
            return nil
        }
    }

    /// The rest of a group whose opening parenthesis was taken.
    private mutating func parenthesized() -> Expression? {
        let allowedUnits = allowsUnits
        allowsUnits = true
        defer { allowsUnits = allowedUnits }
        guard let value = sum(), take(sign: ")") else { return nil }
        return value
    }

    /// A value that starts with a word: a function, a constant, or an amount
    /// with its currency in front.
    private mutating func named() -> Expression? {
        guard let word = peek?.word else { return nil }
        let start = position

        if let function = function() {
            if take(sign: "(") {
                guard let argument = parenthesized() else { return nil }
                return .call(function, argument)
            }
            if take("of") {
                guard let argument = unary() else { return nil }
                return .call(function, argument)
            }
            position = start
        }

        if let constant = Self.constants[word] {
            position += 1
            return .constant(constant)
        }

        // "$100", "USD 100".
        if let match = units.match(tokens, at: position, before: end),
           match.units.allSatisfy({ $0.dimension == .currency }),
           position + match.count < end, tokens[position + match.count].isNumber {
            position += match.count
            guard var amount = primary() else { return nil }
            if let factor = peek.flatMap({ $0.isWord ? Self.exactMultipliers[$0.text] ?? Self.multipliers[$0.text.lowercased()] : nil }) {
                position += 1
                amount = Self.scale(amount, by: factor)
            }
            return .quantity(amount, match.units)
        }
        return nil
    }

    /// Takes the name of a function: "sqrt", "log2", "square root".
    private mutating func function() -> Function? {
        guard let word = peek?.word else { return nil }
        for phrase in Function.phrases where phrase.words.count <= end - position {
            if zip(phrase.words, tokens[position...]).allSatisfy({ $0 == $1.word }) {
                position += phrase.words.count
                return Function.named[phrase.function]
            }
        }
        // The digits of "log2" are a token of their own.
        if position + 1 < end, tokens[position + 1].isNumber, tokens[position + 1].isAttached,
           let function = Function.named[word + tokens[position + 1].text] {
            position += 2
            return function
        }
        guard let function = Function.named[word] else { return nil }
        position += 1
        return function
    }

    private static let constants: [String: Double] = [
        "pi": .pi, "π": .pi, "tau": 2 * .pi, "e": M_E,
    ]

    /// Read in this case only. "M" is a million; "m" is a meter.
    private static let exactMultipliers: [String: Double] = ["k": 1e3, "M": 1e6]

    private static let multipliers: [String: Double] = [
        "thousand": 1e3, "mio": 1e6, "million": 1e6, "bn": 1e9, "billion": 1e9, "trillion": 1e12,
    ]
}
