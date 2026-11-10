import Foundation
import Testing
@testable import InkyCore

/// Throws pieces of calculations and questions together at random. Whatever
/// comes out, the parsers have to end, without a crash, and with an answer
/// that can be shown or with none.
@Suite struct RobustnessTests {
    /// The same sequence on every run, so a failure can be found again.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private static let pieces = [
        "1", "2", "10", "0", "3.5", "1,5", "1.234,5", "1e3", "1e", "0xFF", "0b101", "0x", "18446744073709551615", "007",
        "+", "-", "*", "/", "^", "**", "%", "!", "(", ")", "=", ":", ",", "'", "\"", "√", "→", "->", ".",
        "in", "to", "as", "of", "off", "on", "x", "mod", "plus", "power", "squared", "square", "root",
        "m", "cm", "ft", "km/h", "m2", "oz", "ml", "kg", "h", "min", "s", "d", "C", "F", "K", "k", "M", "MB", "°", "deg",
        "hex", "bin", "dec", "timespan", "sqrt", "sin", "log", "pi", "e", "usd", "eur", "$", "€", "pounds",
        "time", "now", "today", "tomorrow", "monday", "next", "last", "august", "dec", "christmas", "until", "since",
        "between", "and", "days", "weeks", "hours", "diff", "at", "am", "pm", "noon", "the", "th",
        "tokyo", "london", "new", "york", "sf", "utc", "2027", "2027-03-31", "31", "5:30", "é", "🙂", "#", "?",
    ]

    private static let seeds = [
        "2 * ( 3 + 4 )", "200 * 15 %", "- 2 ^ 2", "sqrt ( 16 ) + 1", "5 ft 10 in in cm", "10 in in cm", "72 F to C",
        "8 oz in ml", "1 h 30 m in min", "145 min to timespan", "1 / 2 ft in mm", "255 in hex", "0xFF in bin",
        "20 % off 80", "52 % of 900", "2 power 10", "square root of 625", "100 usd in eur", "$ 100 + € 20",
        "10 k + 5", "sin ( 90 deg )", "2 ^ 10 MB in GB", "10 m / 2 m", "km in mi",
        "time in tokyo", "5 pm london in sf", "5 : 30 pm sf to new york", "time in 4 hours in sf",
        "time diff tokyo", "monday in 3 weeks", "august 5 + 5", "3 : 45 pm + 5", "days until 31 dec",
        "days between 1 dec and 1 feb", "tomorrow at 9 am tokyo", "the 5th of august 2027", "now + 90 min",
    ]

    private static let rates = ExchangeRates(
        day: Date(timeIntervalSince1970: 1_794_000_000),
        perEuro: ["EUR": 1, "USD": 1.25, "GBP": 0.8, "JPY": 160]
    )

    @Test func anythingTypedEndsWithAnAnswerOrNone() {
        let locales = [Locale(identifier: "en_US"), Locale(identifier: "de_DE")]
        let calculators = locales.map { Calculator(locale: $0, units: UnitTable.standard.adding(Self.rates, locale: $0)) }
        let clocks = locales.map { TimeCalculator(locale: $0, timeZone: TimeZone(identifier: "Europe/Berlin")!) }
        let now = Date(timeIntervalSince1970: 1_794_317_400)
        var generator = Generator(state: 2026)
        var answered = 0

        func check(_ input: String) {
            for calculator in calculators {
                if let calculation = calculator.calculate(input) {
                    answered += 1
                    #expect(calculation.value.isFinite, "\(input)")
                    #expect(!calculation.text.isEmpty && !calculation.plain.isEmpty, "\(input)")
                }
            }
            for clock in clocks {
                if let answer = clock.answer(input, now: now) {
                    answered += 1
                    #expect(!answer.title.isEmpty && !answer.subtitle.isEmpty, "\(input)")
                }
            }
        }

        // What the changes start from is understood as it is.
        for seed in Self.seeds {
            let before = answered
            check(seed)
            #expect(answered > before, "\(seed)")
        }

        // Pieces in any order.
        for round in 0..<3000 {
            let count = Int.random(in: 1...9, using: &generator)
            let pieces = (0..<count).map { _ in Self.pieces.randomElement(using: &generator)! }
            // With and without spaces: "5ft10in" is read differently from "5 ft 10 in".
            check(pieces.joined(separator: round.isMultiple(of: 3) ? "" : " "))
        }

        // Something that makes sense, with a piece added, changed or gone.
        for _ in 0..<3000 {
            var words = Self.seeds.randomElement(using: &generator)!.split(separator: " ").map(String.init)
            for _ in 0..<Int.random(in: 1...2, using: &generator) {
                let index = Int.random(in: 0..<words.count, using: &generator)
                switch Int.random(in: 0..<3, using: &generator) {
                case 0: words.insert(Self.pieces.randomElement(using: &generator)!, at: index)
                case 1: words[index] = Self.pieces.randomElement(using: &generator)!
                default: if words.count > 1 { words.remove(at: index) }
                }
            }
            check(words.joined(separator: " "))
        }
        // Enough of it made sense for the test to have tested something.
        #expect(answered > 300)
    }
}
