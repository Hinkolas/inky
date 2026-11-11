import Foundation
import Testing
@testable import InkyCore

@Suite struct TimeTests {
    private static let list = """
    Tokyo\tJP\tAsia/Tokyo
    London\tGB\tEurope/London
    New York City\tUS\tAmerica/New_York
    San Francisco\tUS\tAmerica/Los_Angeles
    Berlin\tDE\tEurope/Berlin
    São Paulo\tBR\tAmerica/Sao_Paulo
    Mumbai\tIN\tAsia/Kolkata
    Köln\tDE\tEurope/Berlin\tKoeln
    Winston-Salem\tUS\tAmerica/New_York
    Brisbane\tAU\tAustralia/Brisbane
    Paris\tFR\tEurope/Paris
    London\tCA\tAmerica/Toronto
    @JP\tAsia/Tokyo
    @GB\tEurope/London
    """

    private static let locale = Locale(identifier: "en_GB")
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!
    private static let places = PlaceIndex(list: list, locale: locale)

    private let calculator = TimeCalculator(locale: locale, timeZone: berlin, places: places)
    /// Tuesday, 10 November 2026, half past two in Berlin.
    private let now = Self.date("2026-11-10T13:30:00Z")

    private static func date(_ timestamp: String) -> Date {
        ISO8601DateFormatter().date(from: timestamp)!
    }

    private static func zone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier)!
    }

    /// The first moment of a day in Berlin.
    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func answer(_ input: String) -> String? {
        calculator.answer(input, now: now).map { "\($0.title) | \($0.subtitle)" }
    }

    // MARK: - The time somewhere

    @Test(arguments: [
        ("time in tokyo", "22:30 | Tokyo, Japan · Today · UTC+9"),
        ("Time In Tokyo", "22:30 | Tokyo, Japan · Today · UTC+9"),
        ("time tokyo", "22:30 | Tokyo, Japan · Today · UTC+9"),
        ("tokyo time", "22:30 | Tokyo, Japan · Today · UTC+9"),
        ("now in tokyo", "22:30 | Tokyo, Japan · Today · UTC+9"),
        ("time in new york", "8:30 | New York City, United States · Today · UTC-5"),
        ("time in nyc", "8:30 | New York City, United States · Today · UTC-5"),
        ("time in sf", "5:30 | San Francisco, United States · Today · UTC-8"),
        ("time in são paulo", "10:30 | São Paulo, Brazil · Today · UTC-3"),
        ("time in sao paulo", "10:30 | São Paulo, Brazil · Today · UTC-3"),
        ("time in cologne", "14:30 | Köln, Germany · Today · UTC+1"),
        ("time in koeln", "14:30 | Köln, Germany · Today · UTC+1"),
        ("time in winston-salem", "8:30 | Winston-Salem, United States · Today · UTC-5"),
        ("time in japan", "22:30 | Japan · Today · UTC+9"),
        ("time in uk", "13:30 | United Kingdom · Today · UTC"),
        ("time in utc", "13:30 | UTC · Today · UTC"),
        // A time zone is known by its own name too.
        ("time in honolulu", "3:30 | Honolulu · Today · UTC-10"),
        ("time in st johns", "10:00 | St Johns · Today · UTC-3:30"),
        ("time in brisbane + 4 hours", "3:30 | Brisbane, Australia · Tomorrow · UTC+10"),
    ])
    func tellsTheTimeSomewhere(input: String, expected: String) {
        #expect(answer(input) == expected)
    }

    @Test func theLargerOfTwoCitiesHasTheName() {
        #expect(calculator.result("time in london", now: now) == .time(
            now, zone: Self.zone("Europe/London"), place: Place(name: "London, United Kingdom", timeZone: Self.zone("Europe/London"))
        ))
    }

    @Test(arguments: [
        ("5pm ldn in sf", "9:00 | San Francisco, United States · Today · UTC-8"),
        ("5pm london in berlin", "18:00 | Berlin, Germany · Today · UTC+1"),
        ("5:30pm sf to nyc", "20:30 | New York City, United States · Today · UTC-5"),
        ("9am tokyo → london", "0:00 | London, United Kingdom · Today · UTC"),
        ("5pm in sf", "8:00 | San Francisco, United States · Today · UTC-8"),
        ("noon in tokyo", "20:00 | Tokyo, Japan · Today · UTC+9"),
        // Without a place to show it in, it is shown where the user is.
        ("5pm sf", "2:00 | Local time · Tomorrow · UTC+1"),
        ("17:30 tokyo", "9:30 | Local time · Today · UTC+1"),
        ("12am tokyo", "16:00 | Local time · Yesterday · UTC+1"),
        ("tomorrow at 9am tokyo", "1:00 | Local time · Tomorrow · UTC+1"),
        ("tomorrow 9am in tokyo", "17:00 | Tokyo, Japan · Tomorrow · UTC+9"),
        ("5 august at 17:00 in sf", "8:00 | San Francisco, United States · Thu, 5 Aug 2027 · UTC-7"),
    ])
    func turnsATimeIntoAnothersTime(input: String, expected: String) {
        #expect(answer(input) == expected)
    }

    @Test(arguments: [
        ("time in 4 hours", "18:30 | Local time · Today · UTC+1"),
        ("time in 1h 30m", "16:00 | Local time · Today · UTC+1"),
        ("time in 4 hours in san francisco", "9:30 | San Francisco, United States · Today · UTC-8"),
        ("now + 90 min", "16:00 | Local time · Today · UTC+1"),
        ("now - 15 hours", "23:30 | Local time · Yesterday · UTC+1"),
        ("3:45pm + 5", "20:45 | Local time · Today · UTC+1"),
        ("3:45pm plus 2 hours and 15 minutes", "18:00 | Local time · Today · UTC+1"),
        ("today + 5 hours", "5:00 | Local time · Today · UTC+1"),
    ])
    func movesATime(input: String, expected: String) {
        #expect(answer(input) == expected)
    }

    @Test(arguments: [
        ("time diff tokyo", "8 hours ahead | Tokyo, Japan · 22:30 now"),
        ("diff sf", "9 hours behind | San Francisco, United States · 5:30 now"),
        ("time difference paris", "Same time | Paris, France · 14:30 now"),
        ("time diff ldn sf", "8 hours behind | San Francisco, United States, compared with London, United Kingdom"),
        ("time difference between london and mumbai", "5 hours 30 minutes ahead | Mumbai, India, compared with London, United Kingdom"),
    ])
    func tellsHowFarClocksAreApart(input: String, expected: String) {
        #expect(answer(input) == expected)
    }

    // MARK: - Days

    @Test(arguments: [
        ("monday in 3 weeks", "Monday, 7 December 2026 | in 27 days"),
        ("next friday", "Friday, 13 November 2026 | in 3 days"),
        ("last monday", "Monday, 9 November 2026 | Yesterday"),
        ("this tuesday", "Tuesday, 10 November 2026 | Today"),
        ("next tuesday", "Tuesday, 17 November 2026 | in 7 days"),
        ("5 august", "Thursday, 5 August 2027 | in 268 days"),
        ("aug 5", "Thursday, 5 August 2027 | in 268 days"),
        ("the 5th of august 2027", "Thursday, 5 August 2027 | in 268 days"),
        ("august 5th, 2025", "Tuesday, 5 August 2025 | 462 days ago"),
        ("august 5 + 5", "Tuesday, 10 August 2027 | in 273 days"),
        ("today + 3 weeks", "Tuesday, 1 December 2026 | in 21 days"),
        ("tomorrow - 10 days", "Sunday, 1 November 2026 | 9 days ago"),
        ("today + 1 month", "Thursday, 10 December 2026 | in 30 days"),
        ("1 jan 2027 - 1 day", "Thursday, 31 December 2026 | in 51 days"),
        // The next one there is.
        ("feb 29", "Tuesday, 29 February 2028 | in 476 days"),
    ])
    func findsADay(input: String, expected: String) {
        #expect(answer(input) == expected)
    }

    @Test(arguments: [
        ("days until 31 mar", "141 days | until Wednesday, 31 March 2027"),
        ("days until christmas", "45 days | until Friday, 25 December 2026"),
        ("how many days until new year's eve", "51 days | until Thursday, 31 December 2026"),
        ("weeks until 24 dec", "6 weeks | until Thursday, 24 December 2026"),
        ("months until 1 june 2027", "6 months | until Tuesday, 1 June 2027"),
        ("days until 2027-03-31", "141 days | until Wednesday, 31 March 2027"),
        ("days until tomorrow", "1 day | until Wednesday, 11 November 2026"),
        ("hours until tomorrow", "9 hours | until Wednesday, 11 November 2026"),
        ("days since 1 jan", "313 days | since Thursday, 1 January 2026"),
        ("days since monday", "1 day | since Monday, 9 November 2026"),
        ("days since 24 dec", "321 days | since Wednesday, 24 December 2025"),
        ("days between 1 dec and 1 feb", "62 days | from Tue 1 Dec to Mon, 1 Feb 2027"),
    ])
    func countsDays(input: String, expected: String) {
        #expect(answer(input) == expected)
    }

    @Test func aDayIsCountedOnTheCalendarAcrossAClockChange() {
        // The day before clocks go forward in Berlin.
        let now = Self.date("2026-03-28T12:00:00Z")
        #expect(calculator.result("now + 1 day", now: now) == .time(Self.date("2026-03-29T11:00:00Z"), zone: Self.berlin, place: nil))
        #expect(calculator.result("now + 24 hours", now: now) == .time(Self.date("2026-03-29T12:00:00Z"), zone: Self.berlin, place: nil))
        #expect(calculator.result("tomorrow at 12:00", now: now) == .time(Self.date("2026-03-29T10:00:00Z"), zone: Self.berlin, place: nil))
        #expect(calculator.result("days until 30 march", now: now) == .count(2, .day, .until(Self.day(2026, 3, 30))))
    }

    @Test func readsATimestamp() {
        #expect(answer("2024-03-15T14:30:00Z") == "15:30 | Local time · Fri, 15 Mar 2024 · UTC+1")
        #expect(answer("2026-11-10T23:59:59.123+09:00") == "15:59 | Local time · Today · UTC+1")
        #expect(calculator.answer("2024-03-15T14:30:00Z", now: now)?.timestamp == "2024-03-15T14:30:00Z")
        #expect(calculator.answer("days until 31 mar", now: now)?.timestamp == nil)
    }

    @Test func namesMonthsAndDaysInTheUsersLanguageToo() {
        let german = TimeCalculator(locale: Locale(identifier: "de_DE"), timeZone: Self.berlin, places: Self.places)
        #expect(german.result("24 dezember", now: now) == .day(Self.day(2026, 12, 24)))
        #expect(german.result("24 december", now: now) == .day(Self.day(2026, 12, 24)))
        #expect(german.result("next mittwoch", now: now) == .day(Self.day(2026, 11, 11)))
        #expect(german.answer("5 märz", now: now)?.title == "Freitag, 5. März 2027")
    }

    // MARK: - What is not a question

    @Test(arguments: [
        // A word on its own is a search.
        "now", "today", "tomorrow", "monday", "christmas", "time", "tokyo", "5pm", "17:30", "may", "diff",
        // Unfinished, or about nothing that is known.
        "time in", "time in t", "time in atlantis", "5pm in", "days until", "time diff", "monday in",
        // A day that does not exist, a time that does not either.
        "30 february", "31 april 2027", "25:00 tokyo", "13pm tokyo", "5:7 tokyo",
        // A whole day has no time somewhere else.
        "tomorrow in tokyo",
        // What the calculator answers.
        "5 m in cm", "2 + 2", "90 min in h", "17", "5 d",
        "time machine", "visual studio code", "",
    ])
    func ignoresWhatAsksNothingAboutTime(input: String) {
        #expect(calculator.result(input, now: now) == nil)
    }

    @Test func theCalculatorLeavesTimeAlone() {
        let sums = Calculator(locale: Self.locale)
        for input in ["time in tokyo", "5pm ldn in sf", "3:45pm + 5", "august 5 + 5", "days until 31 mar", "today + 3 weeks", "monday in 3 weeks"] {
            #expect(sums.calculate(input) == nil)
            #expect(calculator.result(input, now: now) != nil)
        }
    }

    // MARK: - The list that ships

    @Test func theListOfPlacesIsThere() {
        let places = PlaceIndex.shared
        func zone(_ name: String) -> String? {
            guard let tokens = Lexer().tokens(of: name),
                  let match = places.match(tokens, at: 0, before: tokens.count), match.count == tokens.count
            else { return nil }
            return match.place.timeZone.identifier
        }
        #expect(zone("Berlin") == "Europe/Berlin")
        #expect(zone("san francisco") == "America/Los_Angeles")
        #expect(zone("London") == "Europe/London")
        #expect(zone("Mumbai") == "Asia/Kolkata")
        #expect(zone("Beijing") == "Asia/Shanghai")
        #expect(zone("Germany") == "Europe/Berlin")
        #expect(zone("PST") == "America/Los_Angeles")
        #expect(zone("United States") == nil)
        // Every other name for a city is one for a city on the list.
        for alias in PlaceIndex.aliases {
            #expect(zone(alias.alias) == zone(alias.city) && zone(alias.city) != nil, "\(alias.alias) → \(alias.city)")
        }
    }

    @Test func theModuleAnswers() async {
        await MainActor.run {
            let module = TimeModule(calculator: calculator)
            let item = module.instantResults(for: "time diff tokyo").first
            #expect(item?.title == "8 hours ahead" || item?.title == "7 hours ahead")
            #expect(item?.kind == "Time")
            #expect(module.instantResults(for: "2 + 2").isEmpty)
        }
    }
}
