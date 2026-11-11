import Foundation

/// The answer to a question about a time or a day.
public struct TimeAnswer: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    /// The moment the answer is, if it is one, as an ISO 8601 timestamp.
    public var timestamp: String?
}

/// What a question about time comes to, before it is put into words.
enum TimeResult: Sendable, Equatable {
    /// How a count of days is counted.
    enum Reference: Sendable, Equatable {
        case until(Date)
        case since(Date)
        case between(Date, Date)
    }

    /// A time of day, shown as it is in `zone`. `place` is where that is, if
    /// it was asked for by name.
    case time(Date, zone: TimeZone, place: Place?)
    /// A day, as its first moment where the user is.
    case day(Date)
    case count(Int, Calendar.Component, Reference)
    /// How many seconds the clocks of `place` are ahead of those of `other`,
    /// or of the user's own.
    case difference(Int, place: Place, other: Place?)
}

/// Answers questions about times and days as they are typed.
///
/// The time somewhere: "time in tokyo", "5pm london in berlin", "time diff
/// paris". A time or a day some way off: "time in 4 hours", "monday in 3
/// weeks", "5 august + 10". A count of days: "days until 24 dec".
///
/// It reads the same tokens as the calculator and knows a duration by the
/// calculator's units, but a time is not a number, so it is a parser of its
/// own.
public struct TimeCalculator: Sendable {
    public var locale: Locale
    /// Where the user is.
    public var timeZone: TimeZone

    var places: PlaceIndex
    private let names: Names

    public init(locale: Locale = .current, timeZone: TimeZone = .current) {
        self.init(locale: locale, timeZone: timeZone, places: .shared)
    }

    init(locale: Locale, timeZone: TimeZone, places: PlaceIndex) {
        self.locale = locale
        self.timeZone = timeZone
        self.places = places
        names = Names(locale: locale)
    }

    /// The answer to `input`, or nil if it asks nothing about time. A word
    /// on its own, such as "now" or "monday", asks nothing: it is a search.
    public func answer(_ input: String, now: Date = .now) -> TimeAnswer? {
        result(input, now: now).map { describe($0, now: now) }
    }

    func result(_ input: String, now: Date = .now) -> TimeResult? {
        guard Self.supports(now) else { return nil }
        let input = input.trimmingCharacters(in: .whitespaces)
        if let date = Self.timestamp(input) {
            return Self.supports(date) ? .time(date, zone: timeZone, place: nil) : nil
        }
        guard let tokens = Lexer(locale: locale).tokens(of: input), !tokens.isEmpty else { return nil }
        var parser = TimeParser(
            tokens: tokens, places: places, names: names, calendar: calendar(in: timeZone), now: now
        )
        return parser.result()
    }

    /// Keep arithmetic within years 1–9999, where the calendar and ISO date
    /// formatters can represent the answer. A finite duration can overflow
    /// when converted to seconds, or still produce an unrepresentable date.
    static func supports(_ date: Date) -> Bool {
        (-62_135_596_800..<253_402_300_800).contains(date.timeIntervalSince1970)
    }

    private func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = locale
        return calendar
    }

    /// "2024-03-15T14:30:00Z", with or without fractions of a second.
    private static func timestamp(_ input: String) -> Date? {
        // Making a formatter costs more than everything else here, so it is
        // only made for what starts like a timestamp.
        guard input.count >= 16, input.first?.isNumber == true, input.contains("T") || input.contains("t") else { return nil }
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: input.uppercased()) { return date }
        }
        return nil
    }

    // MARK: - Putting it into words

    private func describe(_ result: TimeResult, now: Date) -> TimeAnswer {
        switch result {
        case .time(let date, let zone, let place):
            // Without a place it is the user's own time that is shown.
            let parts = [place?.name ?? "Local time", dayLabel(of: date, in: zone, now: now), Self.offset(of: zone, at: date)]
            return TimeAnswer(
                title: time(date, in: zone),
                subtitle: parts.compactMap { $0 }.joined(separator: " · "),
                timestamp: date.ISO8601Format()
            )
        case .day(let date):
            return TimeAnswer(title: fullDay(date), subtitle: distance(to: date, now: now))
        case .count(let count, let component, let reference):
            let title = Self.counted(count, Self.unitNames[component] ?? "day", locale: locale)
            switch reference {
            case .until(let date):
                return TimeAnswer(title: title, subtitle: "until " + fullDay(date))
            case .since(let date):
                return TimeAnswer(title: title, subtitle: "since " + fullDay(date))
            case .between(let first, let second):
                return TimeAnswer(title: title, subtitle: "from \(shortDay(first, now: now)) to \(shortDay(second, now: now))")
            }
        case .difference(let seconds, let place, let other):
            let title = seconds == 0
                ? "Same time"
                : Self.span(abs(seconds), locale: locale) + (seconds > 0 ? " ahead" : " behind")
            let subtitle = other.map { "\(place.name), compared with \($0.name)" }
                ?? "\(place.name) · \(time(now, in: place.timeZone)) now"
            return TimeAnswer(title: title, subtitle: subtitle)
        }
    }

    private func time(_ date: Date, in zone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        style.timeZone = zone
        return date.formatted(style)
    }

    private func fullDay(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .complete, time: .omitted, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    private func shortDay(_ date: Date, in zone: TimeZone? = nil, now: Date) -> String {
        let zone = zone ?? timeZone
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)
        // The year only where it is not this one.
        if calendar(in: zone).component(.year, from: date) != calendar(in: timeZone).component(.year, from: now) {
            style = style.year()
        }
        style.timeZone = zone
        return date.formatted(style)
    }

    /// How many days after the user's today `date` is, on the calendar of `zone`.
    private func days(to date: Date, in zone: TimeZone, now: Date) -> Int {
        // Both days on one calendar, as if they were in the same place.
        var plain = Calendar(identifier: .gregorian)
        plain.timeZone = .gmt
        let here = calendar(in: timeZone).dateComponents([.year, .month, .day], from: now)
        let there = calendar(in: zone).dateComponents([.year, .month, .day], from: date)
        guard let from = plain.date(from: here), let to = plain.date(from: there) else { return 0 }
        return plain.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// The day `date` is on in `zone`, as seen from the user's today.
    private func dayLabel(of date: Date, in zone: TimeZone, now: Date) -> String {
        switch days(to: date, in: zone, now: now) {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default: shortDay(date, in: zone, now: now)
        }
    }

    private func distance(to date: Date, now: Date) -> String {
        let days = days(to: date, in: timeZone, now: now)
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            let count = Self.counted(abs(days), "day", locale: locale)
            return days > 0 ? "in \(count)" : "\(count) ago"
        }
    }

    /// How far a zone is from Greenwich: "UTC+1", "UTC-3:30". An abbreviation
    /// such as "IST" means three zones, and half the world's have none.
    private static func offset(of zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "UTC" }
        let minutes = abs(seconds) / 60
        let rest = minutes % 60
        return "UTC" + (seconds < 0 ? "-" : "+") + String(minutes / 60) + (rest == 0 ? "" : String(format: ":%02d", rest))
    }

    private static let unitNames: [Calendar.Component: String] = [
        .second: "second", .minute: "minute", .hour: "hour", .day: "day",
        .weekOfYear: "week", .month: "month", .year: "year",
    ]

    /// "1 day", "1,234 days".
    private static func counted(_ count: Int, _ unit: String, locale: Locale) -> String {
        "\(count.formatted(.number.locale(locale))) \(unit)\(abs(count) == 1 ? "" : "s")"
    }

    /// Seconds as hours and minutes: "5 hours 30 minutes".
    private static func span(_ seconds: Int, locale: Locale) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        var parts: [String] = []
        if hours > 0 { parts.append(counted(hours, "hour", locale: locale)) }
        if minutes > 0 || parts.isEmpty { parts.append(counted(minutes, "minute", locale: locale)) }
        return parts.joined(separator: " ")
    }
}

// MARK: - Names of months and days

/// What months, weekdays and a few days of the year are called, in English
/// and in the user's language.
struct Names: Sendable {
    /// January is 1.
    private(set) var months: [String: Int] = [:]
    /// Sunday is 1, as a calendar counts.
    private(set) var weekdays: [String: Int] = [:]

    init(locale: Locale) {
        for locale in [Locale(identifier: "en_US"), locale] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            for symbols in [calendar.standaloneMonthSymbols, calendar.shortStandaloneMonthSymbols] {
                for (index, name) in symbols.enumerated() { add(name, index + 1, to: &months) }
            }
            for symbols in [calendar.standaloneWeekdaySymbols, calendar.shortStandaloneWeekdaySymbols] {
                for (index, name) in symbols.enumerated() { add(name, index + 1, to: &weekdays) }
            }
        }
        months["sept"] = 9
        for (name, weekday) in ["tues": 3, "thur": 5, "thurs": 5] {
            weekdays[name] = weekday
        }
    }

    /// The first to take a name keeps it, and English comes first.
    private func add(_ name: String, _ number: Int, to names: inout [String: Int]) {
        // A short name may end in a full stop, which cannot be typed.
        let key = PlaceIndex.key(name)
        guard !key.isEmpty, !key.contains(" "), names[key] == nil else { return }
        names[key] = number
    }

    /// Days that have a name: the month and the day, by the words that name it.
    static let days: [(words: [String], month: Int, day: Int)] = [
        (["christmas", "eve"], 12, 24), (["christmas", "day"], 12, 25), (["christmas"], 12, 25), (["xmas"], 12, 25),
        (["new", "years", "eve"], 12, 31), (["new", "year", "'", "s", "eve"], 12, 31),
        (["new", "years", "day"], 1, 1), (["new", "year", "'", "s", "day"], 1, 1),
        (["new", "years"], 1, 1), (["new", "year", "'", "s"], 1, 1), (["new", "year"], 1, 1),
        (["halloween"], 10, 31),
    ]
}

// MARK: - Parser

/// Reads tokens as a question about time. Like the calculator's parser it is
/// a recursive descent one, and reads strictly.
private struct TimeParser {
    /// A time or a day that is being worked out.
    private struct Moment {
        var date: Date
        /// The zone it is shown in.
        var zone: TimeZone
        var place: Place?
        /// Whether it is a time of day, or a whole day.
        var hasTime: Bool
        /// Whether it is only what was typed, said back.
        var isTrivial: Bool
    }

    /// A stretch of time to move a moment by.
    private struct Amount {
        var value: Double
        /// What a calendar adds a whole number of: a month is not 30 days.
        var component: Calendar.Component
        var seconds: Double
    }

    /// Which year a day without one is in.
    private enum Year {
        /// Today or the next time it comes.
        case upcoming
        /// Today or the last time it was.
        case past
        case current
    }

    let tokens: [Token]
    let places: PlaceIndex
    let names: Names
    /// The calendar where the user is.
    let calendar: Calendar
    let now: Date

    private var position = 0
    private var end: Int { tokens.count }
    private var home: TimeZone { calendar.timeZone }
    private var today: Date { calendar.startOfDay(for: now) }

    init(tokens: [Token], places: PlaceIndex, names: Names, calendar: Calendar, now: Date) {
        self.tokens = tokens
        self.places = places
        self.names = names
        self.calendar = calendar
        self.now = now
    }

    mutating func result() -> TimeResult? {
        // Each kind of question is tried from the start. One that fits has
        // to take every token.
        if let result = difference(), position == end { return result }
        position = 0
        if let result = count(), position == end { return result }
        position = 0
        if let result = moment(), position == end { return result }
        return nil
    }

    // MARK: - Tokens

    private var peek: Token? {
        position < end ? tokens[position] : nil
    }

    private mutating func take(sign: Character) -> Bool {
        guard peek?.isSymbol(sign) == true else { return false }
        position += 1
        return true
    }

    private mutating func take(_ words: String...) -> Bool {
        take(words)
    }

    private mutating func take(_ words: [String]) -> Bool {
        guard position + words.count <= end,
              zip(words, tokens[position...]).allSatisfy({ $0 == ($1.isWord ? $1.text.lowercased() : $1.text) })
        else { return false }
        position += words.count
        return true
    }

    /// A whole number as it was typed, with at most `digits` digits.
    private mutating func integer(digits: ClosedRange<Int>) -> Int? {
        guard let token = peek, case .number(_, let integer?, 10) = token.kind,
              digits.contains(token.text.count), let value = Int(exactly: integer)
        else { return nil }
        position += 1
        return value
    }

    private mutating func place() -> Place? {
        guard let match = places.match(tokens, at: position, before: end) else { return nil }
        position += match.count
        return match.place
    }

    // MARK: - Questions

    /// "time diff tokyo", "diff london sf".
    private mutating func difference() -> TimeResult? {
        _ = take("time")
        guard take("diff") || take("difference") else { return nil }
        _ = take("between") || take("to") || take("in") || take("with") || take("from")
        guard let first = place() else { return nil }
        if position == end {
            return .difference(first.timeZone.secondsFromGMT(for: now) - home.secondsFromGMT(for: now), place: first, other: nil)
        }
        _ = take("and") || take("to") || take("vs") || take(sign: ",")
        guard let second = place() else { return nil }
        return .difference(
            second.timeZone.secondsFromGMT(for: now) - first.timeZone.secondsFromGMT(for: now),
            place: second, other: first
        )
    }

    /// "days until 24 dec", "weeks since 1 march", "days between 1 jan and 1 mar".
    private mutating func count() -> TimeResult? {
        _ = take("how", "many")
        guard let match = UnitTable.standard.match(tokens, at: position, before: end),
              let unit = match.units.first(where: { $0.dimension == .duration }),
              let component = Self.components[unit.symbol]
        else { return nil }
        position += match.count

        func counted(from: Date, to: Date) -> Int {
            calendar.dateComponents([component], from: from, to: to).value(for: component) ?? 0
        }
        // Hours are counted from this moment, days from the start of today.
        let start = unit.scale < 86_400 ? now : today

        if take("between") {
            guard let first = day(.current), take("and") || take("to"), var second = day(.current) else { return nil }
            // "between 1 dec and 1 feb" runs into the next year.
            if second.date < first.date, !second.hasYear, let later = calendar.date(byAdding: .year, value: 1, to: second.date) {
                second.date = later
            }
            return .count(counted(from: first.date, to: second.date), component, .between(first.date, second.date))
        }
        if take("until") || take("till") || take("til") || take("to") {
            guard let target = day(.upcoming) else { return nil }
            return .count(counted(from: start, to: target.date), component, .until(target.date))
        }
        if take("since") {
            guard let target = day(.past) else { return nil }
            return .count(counted(from: target.date, to: start), component, .since(target.date))
        }
        return nil
    }

    /// A time or a day, moved and shown somewhere else: "5pm london in
    /// berlin", "time in tokyo + 4 hours", "monday in 3 weeks".
    private mutating func moment() -> TimeResult? {
        guard var moment = base() else { return nil }
        while position < end {
            if take(sign: "+") || take("plus") {
                guard move(&moment, by: 1) else { return nil }
            } else if take(sign: "-") || take("minus") {
                guard move(&moment, by: -1) else { return nil }
            } else if take("in") {
                // A place to show it in, or how far off it is.
                if moment.hasTime, let place = place() {
                    moment.zone = place.timeZone
                    moment.place = place
                } else if let amounts = amounts(or: nil) {
                    guard add(amounts, to: &moment, sign: 1) else { return nil }
                } else {
                    return nil
                }
            } else if moment.hasTime, take("to") || take(sign: "→"), let place = place() {
                moment.zone = place.timeZone
                moment.place = place
            } else {
                return nil
            }
            moment.isTrivial = false
        }
        guard !moment.isTrivial else { return nil }
        return moment.hasTime ? .time(moment.date, zone: moment.zone, place: moment.place) : .day(moment.date)
    }

    /// Moves by the amount that comes next. A bare number is hours for a
    /// time and days for a day: "3:45pm + 5", "5 august + 5".
    private mutating func move(_ moment: inout Moment, by sign: Int) -> Bool {
        guard let amounts = amounts(or: moment.hasTime ? .hour : .day) else { return false }
        return add(amounts, to: &moment, sign: sign)
    }

    private func add(_ amounts: [Amount], to moment: inout Moment, sign: Int) -> Bool {
        // Days are counted on the calendar of the place it is shown in.
        var calendar = calendar
        calendar.timeZone = moment.zone
        for amount in amounts {
            guard amount.seconds.isFinite else { return false }
            if amount.value == amount.value.rounded(), abs(amount.value) < 1e6,
               let moved = calendar.date(byAdding: amount.component, value: sign * Int(amount.value), to: moment.date) {
                moment.date = moved
            } else {
                moment.date = moment.date.addingTimeInterval(Double(sign) * amount.seconds)
            }
            guard TimeCalculator.supports(moment.date) else { return false }
            // A day moved by hours is a time.
            if amount.seconds < amount.value * 86_400 { moment.hasTime = true }
        }
        return true
    }

    // MARK: - Moments

    private mutating func base() -> Moment? {
        let start = position

        // "time in tokyo", "time tokyo", "time in 4 hours".
        if take("time") {
            let asked = take("in") || take("at")
            if let place = place() {
                return Moment(date: now, zone: place.timeZone, place: place, hasTime: true, isTrivial: false)
            }
            if asked, let amounts = amounts(or: nil) {
                var moment = Moment(date: now, zone: home, place: nil, hasTime: true, isTrivial: false)
                guard add(amounts, to: &moment, sign: 1) else { return nil }
                return moment
            }
            position = start
            return nil
        }

        // "tokyo time".
        if let place = place() {
            if take("time") {
                return Moment(date: now, zone: place.timeZone, place: place, hasTime: true, isTrivial: false)
            }
            position = start
        }

        if take("now") {
            return Moment(date: now, zone: home, place: nil, hasTime: true, isTrivial: true)
        }

        // "5pm", "5pm london": that time today, there.
        if let clock = clock() {
            let source = place()
            guard let date = date(on: today, at: clock, in: source?.timeZone ?? home) else { return nil }
            return Moment(date: date, zone: home, place: nil, hasTime: true, isTrivial: source == nil)
        }

        // "5 august", "tomorrow at 9am london".
        if let day = day(.upcoming) {
            _ = take(sign: ",")
            let asked = take("at")
            if let clock = clock() {
                let source = place()
                guard let date = date(on: day.date, at: clock, in: source?.timeZone ?? home) else { return nil }
                return Moment(date: date, zone: home, place: nil, hasTime: true, isTrivial: false)
            }
            guard !asked else { return nil }
            return Moment(date: day.date, zone: home, place: nil, hasTime: false, isTrivial: day.isTrivial)
        }
        return nil
    }

    /// The moment the clock shows `clock` in `zone`, on the day that `day`
    /// is where the user is.
    private func date(on day: Date, at clock: (hour: Int, minute: Int, second: Int), in zone: TimeZone) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = clock.hour
        components.minute = clock.minute
        components.second = clock.second
        var there = calendar
        there.timeZone = zone
        return there.date(from: components)
    }

    /// "5pm", "5:30 pm", "17:30", "noon". A bare number is not a time.
    private mutating func clock() -> (hour: Int, minute: Int, second: Int)? {
        let start = position
        if take("noon") || take("midday") { return (12, 0, 0) }
        if take("midnight") { return (0, 0, 0) }

        guard var hour = integer(digits: 1...2) else { return nil }
        var minute = 0
        var second = 0
        var hasMinutes = false
        if take(sign: ":") {
            guard let minutes = integer(digits: 2...2) else {
                position = start
                return nil
            }
            minute = minutes
            hasMinutes = true
            if take(sign: ":") {
                guard let seconds = integer(digits: 2...2) else {
                    position = start
                    return nil
                }
                second = seconds
            }
        }

        if take("am") || take("pm") {
            let isAfternoon = tokens[position - 1].text.lowercased() == "pm"
            guard (1...12).contains(hour) else {
                position = start
                return nil
            }
            hour = hour % 12 + (isAfternoon ? 12 : 0)
        } else if !hasMinutes {
            position = start
            return nil
        }
        guard hour < 24, minute < 60, second < 60 else {
            position = start
            return nil
        }
        return (hour, minute, second)
    }

    // MARK: - Days

    /// A day, as its first moment where the user is. `hasYear` says whether
    /// its year was typed.
    private mutating func day(_ year: Year) -> (date: Date, isTrivial: Bool, hasYear: Bool)? {
        let start = position
        if take("today") { return (today, true, true) }
        if take("tomorrow") { return calendar.date(byAdding: .day, value: 1, to: today).map { ($0, true, true) } }
        if take("yesterday") { return calendar.date(byAdding: .day, value: -1, to: today).map { ($0, true, true) } }

        // "monday", "next monday", "last monday".
        let which = take("next") ? "next" : take("last") ? "last" : take("this") ? "this" : nil
        if let weekday = peek?.word.flatMap({ names.weekdays[PlaceIndex.key($0)] }) {
            position += 1
            // Without a word for it, the coming one, or the last one where
            // the question looks back: "days since monday".
            let direction = which ?? (year == .past ? "last" : "next")
            return self.weekday(weekday, direction).map { ($0, which == nil, true) }
        }
        guard which == nil else {
            position = start
            return nil
        }

        for name in Names.days where take(name.words) {
            return resolve(month: name.month, day: name.day, year: nil, policy: year).map { ($0, true, false) }
        }

        // "2027-03-31".
        if let written = integer(digits: 4...4) {
            if take(sign: "-"), let month = integer(digits: 1...2), take(sign: "-"), let day = integer(digits: 1...2),
               let date = resolve(month: month, day: day, year: written, policy: year) {
                return (date, false, true)
            }
            position = start
            return nil
        }

        // "5 august", "the 5th of august 2027".
        _ = take("the")
        if let day = integer(digits: 1...2) {
            skipOrdinal()
            _ = take("of")
            if let month = month() {
                let written = self.year()
                return resolve(month: month, day: day, year: written, policy: year).map { ($0, false, written != nil) }
            }
            position = start
            return nil
        }

        // "august 5", "august 5th, 2027".
        if let month = month() {
            if let day = integer(digits: 1...2) {
                skipOrdinal()
                let written = self.year()
                return resolve(month: month, day: day, year: written, policy: year).map { ($0, false, written != nil) }
            }
        }
        position = start
        return nil
    }

    private mutating func month() -> Int? {
        guard let month = peek?.word.flatMap({ names.months[PlaceIndex.key($0)] }) else { return nil }
        position += 1
        return month
    }

    /// A year after a day: "2027", ", 2027".
    private mutating func year() -> Int? {
        let start = position
        _ = take(sign: ",")
        if let year = integer(digits: 4...4) { return year }
        position = start
        return nil
    }

    /// The "th" of "5th".
    private mutating func skipOrdinal() {
        if let token = peek, token.isAttached, ["st", "nd", "rd", "th"].contains(token.word) {
            position += 1
        }
    }

    private func weekday(_ weekday: Int, _ direction: String) -> Date? {
        let current = calendar.component(.weekday, from: today)
        var days = (weekday - current + 7) % 7
        switch direction {
        case "last": days = days == 0 ? -7 : days - 7
        case "this": break
        default: if days == 0 { days = 7 }
        }
        return calendar.date(byAdding: .day, value: days, to: today)
    }

    /// The day of a month, in the year that was typed or the one `policy`
    /// picks. A day that does not exist, such as 30 February, is nil.
    private func resolve(month: Int, day: Int, year: Int?, policy: Year) -> Date? {
        func date(in year: Int) -> Date? {
            let components = DateComponents(year: year, month: month, day: day)
            guard let date = calendar.date(from: components),
                  calendar.dateComponents([.year, .month, .day], from: date) == components
            else { return nil }
            return date
        }
        if let year { return date(in: year) }

        let current = calendar.component(.year, from: today)
        switch policy {
        case .current:
            return date(in: current)
        case .upcoming:
            // 29 February may be years away.
            return (current...(current + 8)).lazy.compactMap(date).first { $0 >= today }
        case .past:
            return (0...8).lazy.compactMap { date(in: current - $0) }.first { $0 <= today }
        }
    }

    // MARK: - Amounts

    /// One or more stretches of time: "4 hours", "1h 30m", "2 weeks and 3
    /// days". A number on its own is taken to be of `unit`, if one is given.
    private mutating func amounts(or unit: Calendar.Component?) -> [Amount]? {
        let start = position
        var amounts: [Amount] = []
        while let token = peek, case .number(let value, _, 10) = token.kind {
            position += 1
            if let match = UnitTable.standard.match(tokens, at: position, before: end),
               let unit = match.units.first(where: { $0.dimension == .duration }),
               let component = Self.components[unit.symbol] {
                position += match.count
                amounts.append(Amount(value: value, component: component, seconds: value * unit.scale))
                _ = take("and")
            } else if amounts.isEmpty, let unit, let seconds = Self.seconds[unit] {
                amounts.append(Amount(value: value, component: unit, seconds: value * seconds))
                break
            } else {
                position = start
                return nil
            }
        }
        guard !amounts.isEmpty else {
            position = start
            return nil
        }
        return amounts
    }

    /// What a calendar calls each unit of time, by the unit's symbol.
    private static let components: [String: Calendar.Component] = [
        "s": .second, "min": .minute, "h": .hour, "d": .day, "wk": .weekOfYear, "mo": .month, "yr": .year,
    ]

    private static let seconds: [Calendar.Component: Double] = [.hour: 3600, .day: 86_400]
}
