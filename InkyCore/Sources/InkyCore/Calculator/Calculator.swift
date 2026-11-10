import Foundation

/// Evaluates arithmetic typed into the launcher.
///
/// Supports + - * / ^, parentheses, percent, factorial, `mod`, implicit
/// multiplication ("2pi", "3(4+1)"), common functions and constants.
public struct Calculator: Sendable {
    public var locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// The value of `input`, or nil if it is not a calculation. A bare number
    /// or name is deliberately not one, so searching for "1password" or "pi"
    /// does not turn up a calculator result.
    public func evaluate(_ input: String) -> Double? {
        guard let tokens = tokenize(input), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.isAtEnd, parser.sawOperation, value.isFinite else {
            return nil
        }
        return value
    }

    public func format(_ value: Double, grouping: Bool = true) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.usesGroupingSeparator = grouping
        let magnitude = abs(value)
        if magnitude != 0, magnitude >= 1e15 || magnitude < 1e-9 {
            formatter.numberStyle = .scientific
            formatter.maximumSignificantDigits = 10
            formatter.exponentSymbol = "e"
        } else {
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 10
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Tokens

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case symbol(Character)
    }

    private func tokenize(_ input: String) -> [Token]? {
        let commaIsDecimal = locale.decimalSeparator == ","
        let characters = Array(input)
        var tokens: [Token] = []
        var index = 0

        func isDigit(_ offset: Int) -> Bool {
            offset < characters.count && characters[offset].isASCII && characters[offset].isNumber
        }

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
            } else if isDigit(index) || ((character == "." || character == ",") && isDigit(index + 1)) {
                var text = ""
                scan: while index < characters.count {
                    let current = characters[index]
                    switch current {
                    case _ where isDigit(index):
                        text.append(current)
                    case ".":
                        text.append(".")
                    case "," where commaIsDecimal:
                        text.append(".")
                    case "," where isDigit(index + 1):
                        break // thousands separator
                    case "e", "E":
                        // Only an exponent if a number follows, so "2e" stays 2 × e.
                        if isDigit(index + 1) {
                            text.append("e")
                        } else if index + 1 < characters.count, "+-".contains(characters[index + 1]), isDigit(index + 2) {
                            text.append("e")
                            text.append(characters[index + 1])
                            index += 1
                        } else {
                            break scan
                        }
                    default:
                        break scan
                    }
                    index += 1
                }
                guard let value = Double(text) else { return nil }
                tokens.append(.number(value))
            } else if character.isLetter {
                var name = ""
                while index < characters.count, characters[index].isLetter || isDigit(index) {
                    name.append(characters[index])
                    index += 1
                }
                tokens.append(.identifier(name.lowercased()))
            } else {
                switch character {
                case "+", "-", "/", "^", "%", "!", "(", ")":
                    tokens.append(.symbol(character))
                case "*":
                    if index + 1 < characters.count, characters[index + 1] == "*" {
                        tokens.append(.symbol("^"))
                        index += 1
                    } else {
                        tokens.append(.symbol("*"))
                    }
                case "×", "·": tokens.append(.symbol("*"))
                case "÷": tokens.append(.symbol("/"))
                case "−", "–": tokens.append(.symbol("-"))
                default: return nil
                }
                index += 1
            }
        }
        return tokens
    }

    // MARK: - Parser

    private struct Parser {
        let tokens: [Token]
        var position = 0
        /// Whether anything was actually computed.
        var sawOperation = false

        var isAtEnd: Bool { position == tokens.count }

        private var peek: Token? { position < tokens.count ? tokens[position] : nil }

        private var nextIsIdentifier: Bool {
            if case .identifier = peek { return true }
            return false
        }

        private mutating func take(_ symbol: Character) -> Bool {
            guard peek == .symbol(symbol) else { return false }
            position += 1
            return true
        }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while true {
                if take("+") {
                    guard let rhs = term() else { return nil }
                    value += rhs
                } else if take("-") {
                    guard let rhs = term() else { return nil }
                    value -= rhs
                } else {
                    return value
                }
                sawOperation = true
            }
        }

        private mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while true {
                if take("*") {
                    guard let rhs = unary() else { return nil }
                    value *= rhs
                } else if take("/") {
                    guard let rhs = unary() else { return nil }
                    value /= rhs
                } else if peek == .identifier("mod") {
                    position += 1
                    guard let rhs = unary() else { return nil }
                    value = value.truncatingRemainder(dividingBy: rhs)
                } else if peek == .symbol("(") || nextIsIdentifier {
                    // Implicit multiplication: "2pi", "3(4+1)".
                    guard let rhs = power() else { return nil }
                    value *= rhs
                } else {
                    return value
                }
                sawOperation = true
            }
        }

        private mutating func unary() -> Double? {
            if take("-") { return unary().map { -$0 } }
            if take("+") { return unary() }
            return power()
        }

        private mutating func power() -> Double? {
            guard let base = postfix() else { return nil }
            guard take("^") else { return base }
            guard let exponent = unary() else { return nil }
            sawOperation = true
            return pow(base, exponent)
        }

        private mutating func postfix() -> Double? {
            guard var value = primary() else { return nil }
            while true {
                if take("%") {
                    value /= 100
                } else if take("!") {
                    guard value >= 0, value <= 170, value == value.rounded() else { return nil }
                    value = (1...max(1, Int(value))).reduce(1.0) { $0 * Double($1) }
                } else {
                    return value
                }
                sawOperation = true
            }
        }

        private mutating func primary() -> Double? {
            guard let token = peek else { return nil }
            position += 1
            switch token {
            case .number(let value):
                return value
            case .symbol("("):
                guard let value = expression(), take(")") else { return nil }
                return value
            case .identifier(let name):
                if let function = Calculator.functions[name] {
                    guard take("("), let argument = expression(), take(")") else { return nil }
                    sawOperation = true
                    return function(argument)
                }
                return Calculator.constants[name]
            default:
                return nil
            }
        }
    }

    private static let constants: [String: Double] = [
        "pi": .pi, "π": .pi, "tau": 2 * .pi, "e": M_E,
    ]

    private static let functions: [String: @Sendable (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "cbrt": cbrt, "abs": { abs($0) },
        "sin": sin, "cos": cos, "tan": tan, "asin": asin, "acos": acos, "atan": atan,
        "ln": log, "log": log10, "log2": log2, "exp": exp,
        "round": { $0.rounded() }, "floor": floor, "ceil": ceil,
    ]
}
