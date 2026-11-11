import Foundation

// MARK: - Reading

public extension ColorValue {
    /// The color `text` is, written the way a stylesheet does:
    ///
    ///     #f63  #ff6363  #ff636380
    ///     rgb(255, 99, 99)  rgb(255 99 99 / 50%)
    ///     hsl(0 100% 69%)  hwb(0 39% 0%)
    ///     lab(62 62 33)  lch(62 70 28)  oklab(0.69 0.19 0.08)  oklch(0.69 0.2 23)
    ///
    /// Nil for anything else, a color's name included: "red" is a search.
    init?(_ text: String) {
        // What is copied out of a stylesheet may bring its semicolon along.
        var characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if characters.last == ";" { characters.removeLast() }
        guard !characters.isEmpty, characters.count <= 100 else { return nil }
        var reader = Reader(characters: characters)
        guard let color = reader.color(), reader.isAtEnd else { return nil }
        self = color
    }
}

/// A color that was typed, and the way it is to be written if one was asked
/// for: "#fa32fa in rgb", "rgb(255, 0, 0) to hsl".
public struct ColorRequest: Sendable, Equatable {
    public var color: ColorValue
    /// Nil if only the color was typed.
    public var format: ColorValue.Format?

    public init?(_ text: String) {
        var characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if characters.last == ";" { characters.removeLast() }
        guard !characters.isEmpty, characters.count <= 100 else { return nil }
        var reader = Reader(characters: characters)
        guard let color = reader.color() else { return nil }
        self.color = color
        if !reader.isAtEnd {
            guard reader.asks(), let name = reader.name(), let format = ColorValue.Format(named: name), reader.isAtEnd
            else { return nil }
            self.format = format
        }
    }
}

/// Reads a color one character at a time.
private struct Reader {
    let characters: [Character]
    var index = 0

    /// One of the three or four values between the parentheses.
    struct Part {
        enum Unit {
            case none, percent
            /// An angle, with how many degrees one of it is.
            case angle(Double)
        }

        var value: Double
        var unit: Unit = .none

        /// A share of `whole`, or a plain number as it is.
        func number(of whole: Double) -> Double? {
            switch unit {
            case .none: value
            case .percent: value / 100 * whole
            case .angle: nil
            }
        }

        /// A share from 0 to 1. A plain number counts in hundredths too.
        var share: Double? {
            switch unit {
            case .none, .percent: value / 100
            case .angle: nil
            }
        }

        /// Degrees. A plain number is in degrees.
        var degrees: Double? {
            switch unit {
            case .none: value
            case .percent: nil
            case .angle(let degrees): value * degrees
            }
        }

        /// How see-through, from 0 to 1.
        var alpha: Double? {
            number(of: 1).map { min(1, max(0, $0)) }
        }
    }

    var isAtEnd: Bool {
        var index = index
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        return index == characters.count
    }

    mutating func color() -> ColorValue? {
        if take("#") { return hex() }
        guard let name = word()?.lowercased(), take("("), let parts = parts(commas: name.hasPrefix("rgb") || name.hasPrefix("hsl")),
              take(")")
        else { return nil }
        let alpha = parts.count == 4 ? parts[3].alpha : 1
        guard let alpha else { return nil }
        var color: ColorValue
        switch name {
        case "rgb", "rgba":
            guard let red = parts[0].number(of: 255), let green = parts[1].number(of: 255), let blue = parts[2].number(of: 255)
            else { return nil }
            // Its parts end at 0 and 255.
            let parts = [red, green, blue].map { min(1, max(0, $0 / 255)) }
            color = ColorValue(red: parts[0], green: parts[1], blue: parts[2], notation: .rgb)
        case "hsl", "hsla":
            guard let hue = parts[0].degrees, let saturation = parts[1].share, let lightness = parts[2].share else { return nil }
            color = ColorValue(hsl: (hue, saturation, lightness))
            color.notation = .hsl
        case "hwb":
            guard let hue = parts[0].degrees, let whiteness = parts[1].share, let blackness = parts[2].share else { return nil }
            color = ColorValue(hwb: (hue, whiteness, blackness))
            color.notation = .hwb
        case "lab":
            guard let lightness = parts[0].number(of: 100), let a = parts[1].number(of: 125), let b = parts[2].number(of: 125)
            else { return nil }
            color = ColorValue(lab: (min(100, max(0, lightness)), a, b))
            color.notation = .lab
        case "lch":
            guard let lightness = parts[0].number(of: 100), let chroma = parts[1].number(of: 150), let hue = parts[2].degrees
            else { return nil }
            color = ColorValue(lch: (min(100, max(0, lightness)), max(0, chroma), hue))
            color.notation = .lch
        case "oklab":
            guard let lightness = parts[0].number(of: 1), let a = parts[1].number(of: 0.4), let b = parts[2].number(of: 0.4)
            else { return nil }
            color = ColorValue(oklab: (min(1, max(0, lightness)), a, b))
            color.notation = .oklab
        case "oklch":
            guard let lightness = parts[0].number(of: 1), let chroma = parts[1].number(of: 0.4), let hue = parts[2].degrees
            else { return nil }
            color = ColorValue(oklch: (min(1, max(0, lightness)), max(0, chroma), hue))
            color.notation = .oklch
        default:
            return nil
        }
        guard [color.red, color.green, color.blue].allSatisfy(\.isFinite) else { return nil }
        color.alpha = alpha
        return color
    }

    /// Three, four, six or eight digits after the "#". Three and four are
    /// short for each digit twice.
    private mutating func hex() -> ColorValue? {
        var digits: [Int] = []
        while index < characters.count, let digit = characters[index].hexDigitValue, characters[index].isASCII {
            digits.append(digit)
            index += 1
            if digits.count > 8 { return nil }
        }
        if digits.count == 3 || digits.count == 4 {
            digits = digits.flatMap { [$0, $0] }
        }
        guard digits.count == 6 || digits.count == 8 else { return nil }
        let parts = stride(from: 0, to: digits.count, by: 2).map { Double(digits[$0] * 16 + digits[$0 + 1]) / 255 }
        return ColorValue(red: parts[0], green: parts[1], blue: parts[2], alpha: parts.count == 4 ? parts[3] : 1, notation: .hex)
    }

    /// The values between the parentheses: three, and after a slash how
    /// see-through it is. The older way, for some, puts commas between all
    /// of them.
    private mutating func parts(commas: Bool) -> [Part]? {
        var parts: [Part] = []
        guard let first = part() else { return nil }
        parts.append(first)
        let usesCommas = commas && take(",")
        for count in 1..<3 {
            if usesCommas, count > 1, !take(",") { return nil }
            guard let next = part() else { return nil }
            parts.append(next)
        }
        if take(usesCommas ? "," : "/") {
            guard let alpha = part() else { return nil }
            parts.append(alpha)
        }
        return parts
    }

    private mutating func part() -> Part? {
        skipSpaces()
        let start = index
        if let word = word() {
            // "none" stands for a part that is not there.
            if word.lowercased() == "none" { return Part(value: 0) }
            index = start
            return nil
        }
        guard let value = number() else { return nil }
        if index < characters.count, characters[index] == "%" {
            index += 1
            return Part(value: value, unit: .percent)
        }
        guard let unit = word() else { return Part(value: value) }
        switch unit.lowercased() {
        case "deg": return Part(value: value, unit: .angle(1))
        case "grad": return Part(value: value, unit: .angle(0.9))
        case "rad": return Part(value: value, unit: .angle(180 / .pi))
        case "turn": return Part(value: value, unit: .angle(360))
        default: return nil
        }
    }

    /// A number the way a stylesheet writes it: "-12", ".5", "1.5e-3".
    private mutating func number() -> Double? {
        let start = index
        if index < characters.count, characters[index] == "-" || characters[index] == "+" { index += 1 }
        let whole = digits()
        var fraction = 0
        if index < characters.count, characters[index] == ".", index + 1 < characters.count, characters[index + 1].isASCIIDigit {
            index += 1
            fraction = digits()
        }
        guard whole + fraction > 0 else {
            index = start
            return nil
        }
        // An "e" starts an exponent only if a number follows it.
        if index < characters.count, characters[index] == "e" || characters[index] == "E" {
            let mark = index
            index += 1
            if index < characters.count, characters[index] == "-" || characters[index] == "+" { index += 1 }
            if digits() == 0 { index = mark }
        }
        guard let value = Double(String(characters[start..<index])), value.isFinite else {
            index = start
            return nil
        }
        return value
    }

    /// Skips digits and says how many there were.
    private mutating func digits() -> Int {
        let start = index
        while index < characters.count, characters[index].isASCIIDigit { index += 1 }
        return index - start
    }

    /// Takes the word or the arrow that asks for another way of writing.
    mutating func asks() -> Bool {
        if take("→") { return true }
        let start = index
        if take("-") || take("=") {
            if index < characters.count, characters[index] == ">" {
                index += 1
                return true
            }
            index = start
            return false
        }
        skipSpaces()
        if let word = word(), ["in", "to", "as"].contains(word.lowercased()) { return true }
        index = start
        return false
    }

    /// The word that names a way of writing.
    mutating func name() -> String? {
        skipSpaces()
        return word()
    }

    private mutating func word() -> String? {
        let start = index
        while index < characters.count, characters[index].isASCII, characters[index].isLetter { index += 1 }
        return index > start ? String(characters[start..<index]) : nil
    }

    private mutating func take(_ character: Character) -> Bool {
        skipSpaces()
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }

    private mutating func skipSpaces() {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}

// MARK: - Writing

public extension ColorValue {
    /// The ways a color is written out.
    enum Format: String, Sendable, CaseIterable, Identifiable {
        case hex, rgb, hsl, oklch, hwb, lab, lch, oklab, swiftUI, nsColor, uiColor

        public var id: Self { self }

        public var title: String {
            switch self {
            case .hex: "Hex"
            case .rgb: "RGB"
            case .hsl: "HSL"
            case .oklch: "OKLCH"
            case .hwb: "HWB"
            case .lab: "Lab"
            case .lch: "LCH"
            case .oklab: "OKLab"
            case .swiftUI: "SwiftUI Color"
            case .nsColor: "NSColor"
            case .uiColor: "UIColor"
            }
        }

        /// The format `name` asks for: "rgb", "RGBA", "swiftui".
        init?(named name: String) {
            let name = name.lowercased()
            let other: [String: Format] = ["rgba": .rgb, "hsla": .hsl, "hexadecimal": .hex, "swift": .swiftUI]
            guard let format = other[name] ?? Self.allCases.first(where: { $0.rawValue.lowercased() == name }) else {
                return nil
            }
            self = format
        }

        /// The notation that is read back as this, if a stylesheet has one.
        var notation: Notation? {
            Notation(rawValue: rawValue)
        }
    }

    /// The color written as `format`. Those that can only say what sRGB
    /// shows get the nearest color it does.
    func text(as format: Format) -> String {
        switch format {
        case .hex:
            let color = displayed
            let parts = [color.red, color.green, color.blue] + (alpha < 1 ? [alpha] : [])
            return "#" + parts.map { Self.pair(Int(($0 * 255).rounded())) }.joined()
        case .rgb:
            let color = displayed
            let parts = [color.red, color.green, color.blue].map { Self.number($0 * 255, digits: 0) }
            return alpha < 1
                ? "rgba(\(parts.joined(separator: ", ")), \(alphaText))"
                : "rgb(\(parts.joined(separator: ", ")))"
        case .hsl:
            let (hue, saturation, lightness) = hsl
            return shortest(from: 0, as: displayed) { digits in
                let parts = [
                    Self.number(hue, digits: digits), Self.percent(saturation, digits: digits),
                    Self.percent(lightness, digits: digits),
                ]
                return alpha < 1
                    ? "hsla(\(parts.joined(separator: ", ")), \(alphaText))"
                    : "hsl(\(parts.joined(separator: ", ")))"
            }
        case .hwb:
            let (hue, whiteness, blackness) = hwb
            return shortest(from: 0, as: displayed) { digits in
                function("hwb", [
                    Self.number(hue, digits: digits), Self.percent(whiteness, digits: digits),
                    Self.percent(blackness, digits: digits),
                ])
            }
        case .lab:
            let (lightness, a, b) = lab
            return shortest(from: 1) { digits in
                function("lab", [lightness, a, b].map { Self.number($0, digits: digits) })
            }
        case .lch:
            let (lightness, chroma, hue) = lch
            return shortest(from: 1) { digits in
                function("lch", [lightness, chroma, hue].map { Self.number($0, digits: digits) })
            }
        case .oklab:
            let (lightness, a, b) = oklab
            return shortest(from: 3) { digits in
                function("oklab", [lightness, a, b].map { Self.number($0, digits: digits) })
            }
        case .oklch:
            let (lightness, chroma, hue) = oklch
            return shortest(from: 3) { digits in
                // A hue counts to 360 where the others count to 1.
                function("oklch", [
                    Self.number(lightness, digits: digits), Self.number(chroma, digits: digits),
                    Self.number(hue, digits: digits - 2),
                ])
            }
        case .swiftUI:
            return "Color(" + swiftParts(["red", "green", "blue"]) + (alpha < 1 ? ", opacity: \(Self.number(alpha, digits: 3))" : "") + ")"
        case .nsColor:
            return "NSColor(" + swiftParts(["srgbRed", "green", "blue"]) + ", alpha: \(Self.number(alpha, digits: 3)))"
        case .uiColor:
            return "UIColor(" + swiftParts(["red", "green", "blue"]) + ", alpha: \(Self.number(alpha, digits: 3)))"
        }
    }

    /// What `write` gives with the fewest digits after the point that are
    /// still read back as this color, the way it is counted from 0 to 255.
    private func shortest(from least: Int, as color: ColorValue? = nil, _ write: (Int) -> String) -> String {
        let steps = (color ?? self).steps
        for digits in least..<least + 4 {
            let text = write(digits)
            if let read = ColorValue(text), read.steps == steps { return text }
        }
        return write(least + 4)
    }

    /// How see-through it is, to the hundredth where that is exact enough.
    private var alphaText: String {
        let short = Self.number(alpha, digits: 2)
        let step = Int((alpha * 255).rounded())
        return Double(short).map { Int(($0 * 255).rounded()) } == step ? short : Self.number(alpha, digits: 3)
    }

    private var steps: [Int] {
        [red, green, blue].map { Int(($0 * 255).rounded()) }
    }

    /// The newer way, with spaces, and a slash before how see-through it is.
    private func function(_ name: String, _ parts: [String]) -> String {
        "\(name)(\(parts.joined(separator: " "))" + (alpha < 1 ? " / \(alphaText))" : ")")
    }

    private func swiftParts(_ names: [String]) -> String {
        let color = displayed
        return zip(names, [color.red, color.green, color.blue])
            .map { "\($0): \(Self.number($1, digits: 3))" }
            .joined(separator: ", ")
    }

    private static func pair(_ value: Int) -> String {
        let text = String(min(255, max(0, value)), radix: 16, uppercase: true)
        return text.count == 1 ? "0" + text : text
    }

    private static func percent(_ share: Double, digits: Int) -> String {
        number(share * 100, digits: digits) + "%"
    }

    /// A number with a point, whatever the Mac's language, and no zeros
    /// after its last digit.
    private static func number(_ value: Double, digits: Int) -> String {
        let scale = pow(10, Double(digits))
        let rounded = (value * scale).rounded() / scale
        var text = String(format: "%.\(digits)f", rounded == 0 ? 0 : rounded)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}
