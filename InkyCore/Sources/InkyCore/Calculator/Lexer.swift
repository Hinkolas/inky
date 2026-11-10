import Foundation

/// One piece of what was typed: a number, a word or a symbol.
struct Token: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// `integer` is the exact value of a number written as a whole one.
        /// A double holds whole numbers only up to 2^53.
        case number(Double, integer: UInt64?, radix: Int)
        /// A name: letters, a currency sign, or a degree sign with its letter.
        case word
        case symbol(Character)
    }

    var kind: Kind
    /// As it was typed. A symbol is spelled one way however it was typed, so
    /// "×" and "*" are both "*".
    var text: String
    /// Whether nothing stands between it and the token before it.
    var isAttached: Bool

    var isNumber: Bool {
        if case .number = kind { return true }
        return false
    }

    var isWord: Bool { kind == .word }

    func isSymbol(_ character: Character) -> Bool {
        kind == .symbol(character)
    }

    /// The word in lowercase, or nil if it is not one.
    var word: String? {
        isWord ? text.lowercased() : nil
    }
}

/// Splits what was typed into tokens.
///
/// It gives up on anything it does not know, and the whole input is then not
/// a calculation. Guessing would turn searches into answers.
struct Lexer: Sendable {
    /// Decides whether "1,5" or "1.5" is one and a half.
    var locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func tokens(of input: String) -> [Token]? {
        let characters = Array(input)
        // Nothing typed is this long, and what is pasted may be anything.
        guard characters.count <= Self.longestInput else { return nil }
        var tokens: [Token] = []
        var index = 0
        var isAttached = false

        func add(_ kind: Token.Kind, _ text: String) {
            tokens.append(Token(kind: kind, text: text, isAttached: isAttached))
            isAttached = true
        }

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                isAttached = false
            } else if Self.isDigit(character)
                || (Self.isSeparator(character) && index + 1 < characters.count && Self.isDigit(characters[index + 1])) {
                let start = index
                guard let kind = number(in: characters, at: &index) else { return nil }
                add(kind, String(characters[start..<index]))
            } else if Self.isCurrencySign(character) {
                index += 1
                add(.word, String(character))
            } else if character.isLetter || character == "°" {
                let start = index
                index += 1
                while index < characters.count, characters[index].isLetter || Self.superscripts.contains(characters[index]) {
                    index += 1
                }
                add(.word, String(characters[start..<index]))
            } else {
                guard let symbol = symbol(in: characters, at: &index) else { return nil }
                add(.symbol(symbol), String(symbol))
            }
        }
        return tokens
    }

    // MARK: - Symbols

    private func symbol(in characters: [Character], at index: inout Int) -> Character? {
        let character = characters[index]
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        index += 1
        switch character {
        case "*" where next == "*":
            index += 1
            return "^"
        case "-" where next == ">":
            index += 1
            return "→"
        case "+", "/", "^", "%", "!", "(", ")", ":", ",", "=", "√", "→": return character
        case "*", "×", "·", "⋅", "∗": return "*"
        case "÷", "∕": return "/"
        case "-", "−", "–": return "-"
        case "'", "’", "′": return "'"
        case "\"", "”", "″": return "\""
        default: return nil
        }
    }

    // MARK: - Numbers

    private func number(in characters: [Character], at index: inout Int) -> Token.Kind? {
        func character(_ offset: Int) -> Character? {
            offset < characters.count ? characters[offset] : nil
        }

        // 0xFF, 0b1010, 0o17.
        if characters[index] == "0", let marker = character(index + 1), let radix = Self.radixes[marker],
           let first = character(index + 2), first.isASCII, first.hexDigitValue.map({ $0 < radix }) == true {
            var end = index + 2
            while let digit = character(end), digit.isASCII, let value = digit.hexDigitValue, value < radix {
                end += 1
            }
            // "0b12" and "0xFG" are nothing at all, rather than a number and a rest.
            if let rest = character(end), rest.isLetter || rest.isNumber { return nil }
            guard let value = UInt64(String(characters[(index + 2)..<end]), radix: radix) else { return nil }
            index = end
            return .number(Double(value), integer: value, radix: radix)
        }

        // Digits, with separators only where a digit follows.
        let start = index
        while let current = character(index) {
            if Self.isDigit(current) {
                index += 1
            } else if Self.isSeparator(current), let next = character(index + 1), Self.isDigit(next) {
                index += 1
            } else {
                break
            }
        }
        let digits = String(characters[start..<index])
        guard var decimal = mantissa(digits) else { return nil }
        var isWhole = digits.allSatisfy(Self.isDigit)

        // An exponent only if a number follows, so "2e" stays 2 × e.
        if let marker = character(index), marker == "e" || marker == "E" {
            var end = index + 1
            if let sign = character(end), sign == "+" || sign == "-" { end += 1 }
            let first = end
            while let digit = character(end), Self.isDigit(digit) { end += 1 }
            if end > first {
                decimal += "e" + String(characters[(index + 1)..<end])
                isWhole = false
                index = end
            }
        }
        guard let value = Double(decimal), value.isFinite else { return nil }
        return .number(value, integer: isWhole ? UInt64(digits) : nil, radix: 10)
    }

    /// Digits and separators as "1234.5". The locale says which separator is
    /// the decimal one. Where that reading makes no sense, as in "1.5" for a
    /// German, the other one is tried.
    private func mantissa(_ text: String) -> String? {
        let decimal: Character = locale.decimalSeparator == "," ? "," : "."
        let grouping: Character = decimal == "," ? "." : ","
        return Self.read(text, decimal: decimal, grouping: grouping)
            ?? Self.read(text, decimal: grouping, grouping: decimal)
    }

    private static func read(_ text: String, decimal: Character, grouping: Character) -> String? {
        let parts = text.split(separator: decimal, omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let fraction = parts.count == 2 ? parts[1] : ""
        guard fraction.allSatisfy(isDigit) else { return nil }

        // Groups are of three digits, except the first.
        let groups = parts[0].split(separator: grouping, omittingEmptySubsequences: false)
        if groups.count > 1 {
            guard let first = groups.first, (1...3).contains(first.count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 })
            else { return nil }
        }
        let whole = groups.joined()
        guard !whole.isEmpty || !fraction.isEmpty else { return nil }
        return "\(whole.isEmpty ? "0" : whole).\(fraction.isEmpty ? "0" : String(fraction))"
    }

    static let longestInput = 250

    private static let radixes: [Character: Int] = ["x": 16, "X": 16, "b": 2, "B": 2, "o": 8, "O": 8]
    private static let superscripts: Set<Character> = ["²", "³"]

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "." || character == ","
    }

    private static func isCurrencySign(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.first?.properties.generalCategory == .currencySymbol
    }
}
