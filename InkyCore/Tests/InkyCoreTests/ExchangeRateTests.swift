import Foundation
import Testing
@testable import InkyCore

@MainActor
@Suite struct ExchangeRateTests {
    /// The bank's file, with rates that are easy to reckon with.
    private static func file(day: String = "2026-11-10", dollar: String = "1.25") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
            <gesmes:subject>Reference rates</gesmes:subject>
            <Cube>
                <Cube time='\(day)'>
                    <Cube currency='USD' rate='\(dollar)'/>
                    <Cube currency='GBP' rate='0.8'/>
                    <Cube currency='JPY' rate='160'/>
                    <Cube currency='CHF' rate='0.95'/>
                </Cube>
            </Cube>
        </gesmes:Envelope>
        """.utf8)
    }

    private static let rates = ExchangeRates(ecb: file())!
    private let calculator = Calculator(
        locale: Locale(identifier: "en_US"),
        units: UnitTable.standard.adding(rates, locale: Locale(identifier: "en_US"))
    )

    /// Answers with what it was told to, and counts how often it was asked.
    private final class Bank: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: (Data, Int)?
        private var asked = 0

        init(_ answer: (Data, Int)?) {
            self.answer = answer
        }

        var requests: Int {
            lock.withLock { asked }
        }

        /// Nil makes the request fail.
        func answer(_ answer: (Data, Int)?) {
            lock.withLock { self.answer = answer }
        }

        func fetch(_ url: URL) throws -> (data: Data, status: Int) {
            let answer = lock.withLock {
                asked += 1
                return self.answer
            }
            guard let answer else { throw URLError(.notConnectedToInternet) }
            return answer
        }
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rates-\(UUID().uuidString)")
    }

    private func makeStore(_ bank: Bank, directory: URL? = nil, source: ExchangeRateSource = .ecb) -> ExchangeRateStore {
        ExchangeRateStore(directory: directory ?? makeDirectory(), source: source) { try bank.fetch($0) }
    }

    /// Lets the store's request run until `condition` holds.
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - The file

    @Test func readsTheBanksFile() throws {
        let rates = try #require(ExchangeRates(ecb: Self.file()))
        #expect(rates.perEuro == ["EUR": 1, "USD": 1.25, "GBP": 0.8, "JPY": 160, "CHF": 0.95])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        #expect(calendar.dateComponents([.year, .month, .day], from: rates.day) == DateComponents(year: 2026, month: 11, day: 10))
    }

    @Test func aFileWithoutRatesIsNotOne() {
        #expect(ExchangeRates(ecb: Data("<html><body>Service unavailable</body></html>".utf8)) == nil)
        #expect(ExchangeRates(ecb: Data("<Cube><Cube time='2026-11-10'></Cube></Cube>".utf8)) == nil)
        #expect(ExchangeRates(ecb: Data("<Cube><Cube currency='USD' rate='1.25'/></Cube>".utf8)) == nil)
        #expect(ExchangeRates(ecb: Data("<Cube><Cube time='2026-11-10'><Cube currency='USD' rate='0'/></Cube></Cube>".utf8)) == nil)
        #expect(ExchangeRates(ecb: Data()) == nil)
    }

    // MARK: - Calculating

    @Test(arguments: [
        ("100 usd in eur", "€80.00"),
        ("100 EUR to USD", "$125.00"),
        ("100 gbp in usd", "$156.25"),
        ("100 eur in jpy", "¥16,000"),
        ("$100 in €", "€80.00"),
        ("100$ in euros", "€80.00"),
        ("USD 100 in eur", "€80.00"),
        ("100 dollars in pounds", "£64.00"),
        // The space after a code is one that does not break.
        ("100 us dollars in swiss francs", "CHF\u{a0}76.00"),
        ("$2k in eur", "€1,600.00"),
        ("usd in eur", "€0.80"),
        ("1 jpy in eur", "€0.0063"),
        ("$100 + €20", "$125.00"),
        ("$100 + 20%", "$120.00"),
        ("3 * $20 in eur", "€48.00"),
        ("52% of $900", "$468.00"),
    ])
    func converts(input: String, expected: String) {
        #expect(calculator.calculate(input)?.text == expected)
    }

    @Test func aPoundIsMoneyOrWeightByWhatItIsTurnedInto() {
        #expect(calculator.calculate("100 pounds in eur")?.text == "€125.00")
        #expect(calculator.calculate("100 pounds in kg")?.text == "45.3592 kg")
    }

    @Test func copiesTheNumberAndTheCode() {
        #expect(calculator.calculate("1000 usd in eur")?.plain == "800.00 EUR")
        #expect(calculator.calculate("100 eur in jpy")?.plain == "16000 JPY")
    }

    @Test func tellsWhetherRatesWereUsed() {
        #expect(calculator.calculate("100 usd in eur")?.usesExchangeRates == true)
        #expect(calculator.calculate("$100 + €20")?.usesExchangeRates == true)
        #expect(calculator.calculate("$100 * 2")?.usesExchangeRates == false)
        #expect(calculator.calculate("10 ft in m")?.usesExchangeRates == false)
    }

    @Test func withoutRatesACurrencyIsNotUnderstood() {
        let plain = Calculator(locale: Locale(identifier: "en_US"))
        for input in ["100 usd in eur", "$100 in €", "$100 * 2", "usd in eur"] {
            #expect(plain.calculate(input) == nil)
        }
    }

    // MARK: - The store

    @Test func fetchesAndKeepsTheRates() async throws {
        let bank = Bank((Self.file(), 200))
        let directory = makeDirectory()
        let store = makeStore(bank, directory: directory)
        #expect(store.rates == nil)

        store.update()
        await wait { store.rates != nil }
        #expect(store.rates == Self.rates)
        #expect(store.fetched != nil)
        #expect(!store.isUpdating)
        #expect(!store.failed)

        // What was fetched is there for the next launch, without asking.
        let next = makeStore(bank, directory: directory)
        #expect(next.rates == Self.rates)
        next.update()
        #expect(bank.requests == 1)
    }

    @Test func asksAgainOnlyOnceTheRatesAreOld() async {
        let bank = Bank((Self.file(), 200))
        let store = makeStore(bank)
        store.update()
        await wait { store.rates != nil }

        store.update(now: Date.now.addingTimeInterval(ExchangeRateStore.lifetime - 60))
        #expect(bank.requests == 1)

        bank.answer((Self.file(day: "2026-11-11", dollar: "1.5"), 200))
        store.update(now: Date.now.addingTimeInterval(ExchangeRateStore.lifetime + 60))
        await wait { store.rates?.perEuro["USD"] == 1.5 }
        #expect(bank.requests == 2)
        #expect(store.rates?.perEuro["USD"] == 1.5)
    }

    @Test func aRequestThatFailsLeavesTheRatesAlone() async {
        let bank = Bank((Self.file(), 200))
        let store = makeStore(bank)
        store.update()
        await wait { store.rates != nil }

        for answer: (Data, Int)? in [nil, (Data("oops".utf8), 200), (Self.file(), 503)] {
            bank.answer(answer)
            let before = bank.requests
            store.refresh()
            await wait { bank.requests > before && !store.isUpdating }
            #expect(store.failed)
            #expect(store.rates == Self.rates)
        }

        // It is left alone for a while, then tried again.
        let asked = bank.requests
        store.update(now: Date.now.addingTimeInterval(ExchangeRateStore.lifetime + 60))
        #expect(bank.requests == asked)
        bank.answer((Self.file(), 200))
        store.update(now: Date.now.addingTimeInterval(ExchangeRateStore.lifetime + ExchangeRateStore.retryDelay + 60))
        await wait { !store.failed }
        #expect(!store.failed)
    }

    @Test func withoutASourceNothingIsAskedOrKnown() async {
        let bank = Bank((Self.file(), 200))
        let directory = makeDirectory()
        let store = makeStore(bank, directory: directory, source: .off)
        store.update()
        store.refresh()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(bank.requests == 0)
        #expect(store.rates == nil)

        // Turned on, it fetches. Turned off again, the rates are gone at once.
        store.source = .ecb
        await wait { store.rates != nil }
        #expect(store.rates == Self.rates)
        store.source = .off
        #expect(store.rates == nil)
        store.update()
        #expect(bank.requests == 1)

        // What was kept is used again when it is turned back on.
        store.source = .ecb
        #expect(store.rates == Self.rates)
        #expect(bank.requests == 1)
    }

    // MARK: - The provider

    @Test func theProviderUsesTheRatesItHas() async throws {
        let bank = Bank((Self.file(), 200))
        let store = makeStore(bank)
        let provider = CalculatorProvider(calculator: Calculator(locale: Locale(identifier: "en_US")), exchangeRates: store)

        var changes = 0
        provider.onChange = { changes += 1 }

        // The first thing typed asks for the rates. When they are there, the
        // provider says that what is on screen is out of date.
        #expect(provider.instantResults(for: "100 usd in eur").isEmpty)
        await wait { changes == 1 }
        #expect(changes == 1)

        let item = try #require(provider.instantResults(for: " 100 usd in eur ").first)
        #expect(item.title == "€80.00")
        #expect(item.subtitle == "100 usd in eur · rates of Nov 10, 2026")
        #expect(provider.instantResults(for: "10 ft in m").first?.subtitle == "10 ft in m")

        store.source = .off
        await wait { changes == 2 }
        #expect(changes == 2)
        #expect(provider.instantResults(for: "100 usd in eur").isEmpty)
        #expect(provider.instantResults(for: "10 ft in m").first?.title == "3.048 m")
    }

    @Test func aProviderWithoutAStoreStillCalculates() {
        let provider = CalculatorProvider(calculator: Calculator(locale: Locale(identifier: "en_US")))
        #expect(provider.instantResults(for: "2 + 2").first?.title == "4")
        #expect(provider.instantResults(for: "100 usd in eur").isEmpty)
    }
}
