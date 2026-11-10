import Foundation
import Testing
@testable import InkyCore

@Suite struct CalculatorTests {
    private let calculator = Calculator(locale: Locale(identifier: "en_US"))

    @Test(arguments: [
        ("1+2", 3.0),
        ("2 * (3 + 4)", 14),
        ("10 / 4", 2.5),
        ("2^10", 1024),
        ("2**3", 8),
        ("-2^2", -4),
        ("2^-1", 0.5),
        ("2^3^2", 512),
        ("10 - 2 - 3", 5),
        ("200 * 15%", 30),
        ("5!", 120),
        ("7 mod 4", 3),
        ("sqrt(16) + 1", 5),
        ("2(3+4)", 14),
        ("1,000 + 1", 1001),
        ("1e3 + 1", 1001),
        (".5 + .5", 1),
        ("6 ÷ 2 × 3", 9),
    ])
    func evaluates(input: String, expected: Double) throws {
        let value = try #require(calculator.evaluate(input))
        #expect(abs(value - expected) < 1e-9)
    }

    @Test func understandsConstants() throws {
        let value = try #require(calculator.evaluate("2pi"))
        #expect(abs(value - 2 * .pi) < 1e-9)
    }

    @Test(arguments: ["42", "pi", "safari", "1password", "7zip", "(5)", "-5", "1 +", "2 * (3", "1/0", "sqrt(-1)", ""])
    func ignoresWhatIsNotACalculation(input: String) {
        #expect(calculator.evaluate(input) == nil)
    }

    @Test func readsCommaAsDecimalWhereTheLocaleDoes() throws {
        let german = Calculator(locale: Locale(identifier: "de_DE"))
        #expect(try #require(german.evaluate("1,5 + 1")) == 2.5)
        #expect(german.format(1234.5) == "1.234,5")
    }

    @Test func formatsWithoutFloatingPointNoise() {
        #expect(calculator.format(0.1 + 0.2) == "0.3")
        #expect(calculator.format(1_234_567) == "1,234,567")
        #expect(calculator.format(1_234_567, grouping: false) == "1234567")
    }
}
