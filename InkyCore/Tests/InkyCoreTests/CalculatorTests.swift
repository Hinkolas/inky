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
        ("2 + 2 =", 4),
        ("√16 + 1", 5),
        ("log2(8)", 3),
        ("log10(1000)", 3),
        ("2 sqrt(9)", 6),
        ("sinh(0) + 1", 1),
    ])
    func evaluates(input: String, expected: Double) throws {
        let value = try #require(calculator.evaluate(input))
        #expect(abs(value - expected) < 1e-9)
    }

    @Test func understandsConstants() throws {
        let value = try #require(calculator.evaluate("2pi"))
        #expect(abs(value - 2 * .pi) < 1e-9)
    }

    @Test(arguments: [
        "42", "pi", "safari", "1password", "7zip", "(5)", "-5", "1 +", "2 * (3", "1/0", "sqrt(-1)", "",
        // An amount on its own is a search too.
        "4k", "10k", "5 m", "3d", "10 in", "in", "2x", "9 to 5", "1 in 3", "sqrt", "sqrt 16",
    ])
    func ignoresWhatIsNotACalculation(input: String) {
        #expect(calculator.calculate(input) == nil)
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

    // MARK: - Numbers as they are typed

    @Test func readsASeparatorTheWayThatMakesSense() throws {
        let german = Calculator(locale: Locale(identifier: "de_DE"))
        // Groups of three are thousands, in the way of the locale.
        #expect(calculator.evaluate("1,234 + 1") == 1235)
        #expect(german.evaluate("1.234 + 1") == 1235)
        #expect(calculator.evaluate("1,234,567.5 + 1") == 1_234_568.5)
        #expect(german.evaluate("1.234.567,5 + 1") == 1_234_568.5)
        // Anything else can only be a decimal, whoever types it.
        #expect(calculator.evaluate("1,5 + 1") == 2.5)
        #expect(german.evaluate("1.5 + 1") == 2.5)
        #expect(calculator.evaluate("1.234,5 + 1") == 1235.5)
        #expect(german.evaluate("1,234.5 + 1") == 1235.5)
        #expect(calculator.calculate("1.2.3 + 1") == nil)
        #expect(calculator.calculate("1,23,4 + 1") == nil)
    }

    @Test func anExponentNeedsANumber() throws {
        #expect(calculator.evaluate("1.5e3 + 1") == 1501)
        #expect(calculator.evaluate("1e-3 * 1000") == 1)
        let value = try #require(calculator.evaluate("2e + 1"))
        #expect(abs(value - (2 * M_E + 1)) < 1e-9)
    }

    @Test func aSignItDoesNotKnowEndsIt() {
        for input in ["2 + 2 #", "2 & 3", "1 + 1.", "a@b", "5 < 6"] {
            #expect(calculator.calculate(input) == nil)
        }
    }

    @Test func whatIsFarTooLongIsNotRead() {
        let sum = Array(repeating: "1", count: 100).joined(separator: "+")
        #expect(calculator.evaluate(sum) == 100)
        #expect(calculator.calculate(sum + "+" + sum) == nil)
        // However deep, it ends without an answer.
        #expect(calculator.calculate(String(repeating: "(", count: 250)) == nil)
        #expect(calculator.calculate(String(repeating: "-", count: 249) + "1") == nil)
        #expect(calculator.calculate(String(repeating: "√", count: 249) + "4") == nil)
        #expect(calculator.calculate(String(repeating: "2^", count: 120) + "2") == nil)
        #expect(calculator.calculate(String(repeating: "(", count: 100) + "1+1" + String(repeating: ")", count: 100)) == nil)
        // What anyone would type is nowhere near the limit.
        #expect(calculator.evaluate("((((((((((1 + 1))))))))))") == 2)
        #expect(calculator.evaluate("-(-(-(-(2^(1+(2*(3-1)))))))") == 32)
    }

    // MARK: - Words

    @Test(arguments: [
        ("52% of 900", "468"),
        ("20% off 80", "64"),
        ("10% on 80", "88"),
        ("80 + 20%", "96"),
        ("80 - 20%", "64"),
        ("10% + 5%", "0.15"),
        ("square root of 625", "25"),
        ("cube root of 27", "3"),
        ("2 power 10", "1,024"),
        ("2 to the power of 10", "1,024"),
        ("5 squared", "25"),
        ("2 cubed", "8"),
        ("3 x 4", "12"),
        ("3 times 4 plus 2", "14"),
        ("10 divided by 4", "2.5"),
        ("10 minus 4", "6"),
        ("10k + 5", "10,005"),
        ("2M * 2", "4,000,000"),
        ("1.5 million / 3", "500,000"),
        ("3 bn / 1 thousand", "3,000,000"),
    ])
    func understandsWords(input: String, expected: String) {
        #expect(calculator.calculate(input)?.text == expected)
    }

    // MARK: - Units

    @Test(arguments: [
        ("10 ft in m", "3.048 m"),
        ("10ft to m", "3.048 m"),
        ("10 ft as m", "3.048 m"),
        ("10 feet → meters", "3.048 m"),
        ("10 ft -> m", "3.048 m"),
        ("1 mi in km", "1.60934 km"),
        ("72 F to C", "22.2222 °C"),
        ("100 °C in °F", "212 °F"),
        ("0 K in F", "-459.67 °F"),
        ("20 degrees celsius in fahrenheit", "68 °F"),
        ("60 mph in km/h", "96.5606 km/h"),
        ("100 km/h in m/s", "27.7778 m/s"),
        ("1 GB in MB", "1,000 MB"),
        ("1 GiB in MB", "1,073.74 MB"),
        ("5 m2 in sq ft", "53.8196 ft²"),
        ("1 acre in m^2", "4,046.86 m²"),
        ("2 weeks in h", "336 h"),
        ("180 deg in rad", "3.14159 rad"),
        ("1 rad in deg", "57.2958°"),
        ("1 kWh in J", "3,600,000 J"),
        ("1 atm in psi", "14.6959 psi"),
        ("2 tbsp in ml", "29.5735 ml"),
        ("1 l in fl oz", "33.814 fl oz"),
        ("0.001 mm in m", "0.000001 m"),
        ("1 stone in lbs", "14 lb"),
        ("145 mins to timespan", "2 h 25 min"),
        ("1.5 d to timespan", "1 d 12 h"),
        ("90 s to timespan", "1 min 30 s"),
    ])
    func converts(input: String, expected: String) {
        #expect(calculator.calculate(input)?.text == expected)
    }

    @Test(arguments: [
        ("2 m + 50 cm", "2.5 m"),
        ("50 cm + 2 m", "250 cm"),
        ("10 km / 2", "5 km"),
        ("3 * 2 kg", "6 kg"),
        ("10 m / 2 m", "5"),
        ("1 km / 1 m", "1,000"),
        ("20% of 50 kg", "10 kg"),
        ("50 kg - 10%", "45 kg"),
        ("20 C + 5", "25 °C"),
        ("round(3.7 m)", "4 m"),
        ("sin(90 deg)", "1"),
        ("-5 m + 2 m", "-3 m"),
        ("2^10 MB in GB", "1.024 GB"),
        ("(1 + 2) km in m", "3,000 m"),
        ("10 ft in m in cm", "304.8 cm"),
    ])
    func calculatesWithUnits(input: String, expected: String) {
        #expect(calculator.calculate(input)?.text == expected)
    }

    @Test(arguments: [
        ("5 ft 10 in in cm", "177.8 cm"),
        ("5'10\" in cm", "177.8 cm"),
        ("5 feet 10 inches in m", "1.778 m"),
        ("1h 30m in min", "90 min"),
        ("1 h 30 min 30 s in s", "5,430 s"),
        ("1/2 inch in mm", "12.7 mm"),
        ("3/4 cup in ml", "177.441 ml"),
    ])
    func addsUpAmountsInARow(input: String, expected: String) {
        #expect(calculator.calculate(input)?.text == expected)
    }

    @Test func aNameThatAsksAndMeasuresIsToldApart() {
        // "in" is the inch and the word that asks for a conversion.
        #expect(calculator.calculate("10 in in cm")?.text == "25.4 cm")
        #expect(calculator.calculate("3 ft to in")?.text == "36 in")
        #expect(calculator.calculate("5 in + 3 cm in mm")?.text == "157 mm")
        #expect(calculator.calculate("ft in in")?.text == "12 in")
    }

    @Test func aNameWithTwoMeaningsIsTheOneThatFits() {
        #expect(calculator.calculate("8 oz in ml")?.text == "236.588 ml")
        #expect(calculator.calculate("8 oz in g")?.text == "226.796 g")
        // A minute next to an hour, a meter otherwise.
        #expect(calculator.calculate("90 m in h")?.text == "1.5 h")
        #expect(calculator.calculate("90 m in km")?.text == "0.09 km")
    }

    @Test func caseDecidesWhereItMatters() {
        #expect(calculator.calculate("8 Mb in MB")?.text == "1 MB")
        #expect(calculator.calculate("500 mb in gb")?.text == "0.5 GB")
        #expect(calculator.calculate("300 K in C")?.text == "26.85 °C")
        #expect(calculator.calculate("300 k + 1")?.text == "300,001")
        #expect(calculator.calculate("5 KM in M")?.text == "5,000 m")
    }

    @Test func aUnitOnItsOwnIsOneOfIt() {
        #expect(calculator.calculate("km in mi")?.text == "0.621371 mi")
        #expect(calculator.calculate("mile to km")?.text == "1.60934 km")
    }

    @Test(arguments: [
        "10 m * 2 m", "5 m in kg", "5 in cm", "10 / (2 m + 1 m)", "(2 m)^2", "5 m + 2 kg", "20 C / 10 C", "sqrt(4 m)",
        "10 m in hex", "5 kg to timespan", "10 usd in eur", "$100 + 1",
    ])
    func givesNoAnswerWhereThereIsNone(input: String) {
        #expect(calculator.calculate(input) == nil)
    }

    @Test func copiesWithoutGrouping() {
        #expect(calculator.calculate("1 acre in m^2")?.plain == "4046.86 m²")
        #expect(calculator.calculate("1000 * 1000")?.plain == "1000000")
        #expect(calculator.calculate("72 F to C")?.unit?.symbol == "°C")
    }

    // MARK: - The units of a web page

    @Test(arguments: [
        ("2rem in px", "32 px"),
        ("32px in rem", "2 rem"),
        ("1.5 em to pixels", "24 px"),
        ("2em in px", "32 px"),
        ("1rem + 8px", "1.5 rem"),
        ("1920 px / 2", "960 px"),
        ("rem in px", "16 px"),
    ])
    func convertsTheUnitsOfAWebPage(input: String, expected: String) {
        let calculator = Calculator(locale: calculator.locale, units: UnitTable.standard.adding(pixelsPerRem: 16))
        #expect(calculator.calculate(input)?.text == expected)
    }

    @Test func aRemIsAsLargeAsItIsSaidToBe() {
        let calculator = Calculator(locale: calculator.locale, units: UnitTable.standard.adding(pixelsPerRem: 10))
        #expect(calculator.calculate("2rem in px")?.text == "20 px")
        #expect(calculator.calculate("25px in rem")?.text == "2.5 rem")
    }

    @Test func aPixelIsNotALengthToMeasure() {
        let calculator = Calculator(locale: calculator.locale, units: UnitTable.standard.adding(pixelsPerRem: 16))
        #expect(calculator.calculate("2 in in px") == nil)
        #expect(calculator.calculate("96 px in cm") == nil)
        // On its own it is a search.
        #expect(calculator.calculate("2rem") == nil)
        // A rem that is nothing is not known, and a pixel still is.
        let without = Calculator(locale: calculator.locale, units: UnitTable.standard.adding(pixelsPerRem: 0))
        #expect(without.calculate("2rem in px") == nil)
        #expect(without.calculate("10 px + 5 px")?.text == "15 px")
    }

    @MainActor
    @Test func theProviderIsToldHowLargeARemIs() {
        let provider = CalculatorProvider(calculator: Calculator(locale: Locale(identifier: "en_US")))
        #expect(provider.instantResults(for: "2rem in px").first?.title == "32 px")
        provider.pixelsPerRem = 10
        #expect(provider.instantResults(for: "2rem in px").first?.title == "20 px")
    }

    // MARK: - Bases

    @Test(arguments: [
        ("0xFF", "255"),
        ("0b1010", "10"),
        ("0o17", "15"),
        ("0xff + 1", "256"),
        ("255 in hex", "0xFF"),
        ("255 to hexadecimal", "0xFF"),
        ("10 as binary", "0b1010"),
        ("8 in oct", "0o10"),
        ("0xFF in dec", "255"),
        ("0b1010 to hex", "0xA"),
        ("-255 in hex", "-0xFF"),
        ("2^8 - 1 in hex", "0xFF"),
        ("255 in hex in bin", "0b11111111"),
        // Larger than a double holds exactly.
        ("0xFFFFFFFFFFFFFFFF in dec", "18,446,744,073,709,551,615"),
        ("18446744073709551615 in hex", "0xFFFFFFFFFFFFFFFF"),
    ])
    func writesWholeNumbersInOtherBases(input: String, expected: String) {
        #expect(calculator.calculate(input)?.text == expected)
    }

    @Test(arguments: ["1.5 in hex", "0b12", "0xFG", "0x", "0x1FFFFFFFFFFFFFFFF", "2^60 + 1 in hex"])
    func aNumberThatIsNotWholeAndExactHasNoOtherBase(input: String) {
        #expect(calculator.calculate(input) == nil)
    }
}
