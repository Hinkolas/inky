import Foundation

/// Scores how well a typed pattern matches a name.
///
/// The pattern has to appear in the target as a subsequence. Among all the ways
/// it can be laid over the target the best one wins: characters that start a
/// word or follow each other score high, gaps cost a little. This is what makes
/// "vsc" find "Visual Studio Code" and "saf" prefer "Safari" over "Disk Safety".
public enum FuzzyMatcher {
    public struct Pattern: Sendable {
        let scalars: [Unicode.Scalar]

        public init(_ string: String) {
            scalars = Array(fold(string.trimmingCharacters(in: .whitespaces)).unicodeScalars)
        }

        public var isEmpty: Bool { scalars.isEmpty }
    }

    public struct Target: Sendable {
        let scalars: [Unicode.Scalar]
        /// What a match at each position is worth, from what precedes it.
        let bonus: [Double]

        public init(_ string: String) {
            var scalars: [Unicode.Scalar] = []
            var bonus: [Double] = []
            var previous: Character?
            for character in string.prefix(maxLength) {
                var value = positionBonus(previous: previous, current: character)
                for scalar in fold(character).unicodeScalars {
                    scalars.append(scalar)
                    bonus.append(value)
                    value = 0
                }
                previous = character
            }
            self.scalars = scalars
            self.bonus = bonus
        }
    }

    /// Returns 0...1, where 1 is an exact match, or nil if the pattern does not
    /// occur in the target at all.
    public static func score(_ pattern: Pattern, in target: Target) -> Double? {
        let p = pattern.scalars
        let t = target.scalars
        let n = p.count
        let m = t.count
        guard n > 0, n <= m else { return nil }

        var matched = 0
        for scalar in t where scalar == p[matched] {
            matched += 1
            if matched == n { break }
        }
        guard matched == n else { return nil }
        if n == m { return 1 }

        // bestEndingHere[j]: best score with p[i] placed exactly on t[j].
        // bestUpTo[j]: best score for p[0...i] placed anywhere in t[0...j].
        let none = -Double.infinity
        var previousEndingHere = [Double](repeating: none, count: m)
        var previousUpTo = [Double](repeating: none, count: m)
        var endingHere = previousEndingHere
        var upTo = previousUpTo

        for i in 0..<n {
            var running = none
            let gap = i == n - 1 ? gapTrailing : gapInner
            for j in 0..<m {
                if p[i] == t[j] {
                    var score = none
                    if i == 0 {
                        score = Double(j) * gapLeading + target.bonus[j]
                    } else if j > 0 {
                        score = max(
                            previousUpTo[j - 1] + target.bonus[j],
                            previousEndingHere[j - 1] + consecutive
                        )
                    }
                    endingHere[j] = score
                    running = max(score, running + gap)
                } else {
                    endingHere[j] = none
                    running += gap
                }
                upTo[j] = running
            }
            swap(&previousEndingHere, &endingHere)
            swap(&previousUpTo, &upTo)
        }

        let best = bonusStart + Double(n - 1) * consecutive
        return min(0.99, max(0, previousUpTo[m - 1] / best))
    }

    public static func score(_ pattern: String, in target: String) -> Double? {
        score(Pattern(pattern), in: Target(target))
    }

    // MARK: - Tuning

    private static let maxLength = 200
    private static let gapLeading = -0.005
    private static let gapTrailing = -0.005
    private static let gapInner = -0.01
    private static let consecutive = 1.0
    private static let bonusStart = 0.9
    private static let bonusWord = 0.8
    private static let bonusCapital = 0.7
    private static let bonusDot = 0.6

    private static func positionBonus(previous: Character?, current: Character) -> Double {
        guard let previous else { return bonusStart }
        if previous == "/" { return bonusStart }
        if previous == "." { return bonusDot }
        if previous == "-" || previous == "_" || previous.isWhitespace { return bonusWord }
        if previous.isLowercase, current.isUppercase { return bonusCapital }
        return 0
    }

    private static func fold(_ character: Character) -> String {
        if character.isASCII { return character.lowercased() }
        return fold(String(character))
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
