import Foundation

/// Sorts a copied text into what it looks like, and words what is shown of it.
public enum ClipClassifier {
    /// What `text` looks like: a color, a link, a path to something that is
    /// there, or text.
    public static func kind(of text: String, fileExists: (String) -> Bool) -> ClipKind {
        // Only a short text on one line can be anything but text. Of a long
        // one, no more is looked at than it takes to tell.
        let scalars = text.unicodeScalars
        let isSpace = { CharacterSet.whitespacesAndNewlines.contains($0) }
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return .text }
        let line = Substring(scalars[first...last])
        guard line.prefix(201).count <= 200, !line.contains(where: \.isNewline) else { return .text }

        let trimmed = String(line)
        if isColor(trimmed) { return .color }
        if isLink(trimmed) { return .link }
        // Much begins with a slash without being a path: "/help", the path
        // of a web address. What counts is that something is there.
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/"), trimmed.count > 1, fileExists(expandedPath(trimmed)) {
            return .path
        }
        return .text
    }

    /// The path with the home folder written out.
    public static func expandedPath(_ text: String) -> String {
        (text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    /// One line to list the text by: its first line that says something,
    /// and a link without what every link begins with.
    public static func title(of text: String, kind: ClipKind) -> String {
        var title = ""
        if let line = firstLine(of: text) {
            // Its words, one space apart. More than the title holds is not
            // needed: at most a link's beginning and end come off below.
            var characters = 0
            var space = false
            for character in line {
                if character.isNewline { break }
                if character.isWhitespace {
                    space = !title.isEmpty
                    continue
                }
                if space {
                    title.append(" ")
                    characters += 1
                    space = false
                }
                title.append(character)
                characters += 1
                if characters > maxTitleLength + 16 { break }
            }
        }
        if kind == .link {
            for prefix in ["https://", "http://"] where title.lowercased().hasPrefix(prefix) {
                title.removeFirst(prefix.count)
            }
            if title.lowercased().hasPrefix("www.") { title.removeFirst(4) }
            if title.hasSuffix("/") { title.removeLast() }
        }
        return String(title.prefix(maxTitleLength))
    }

    static let maxTitleLength = 240

    /// The text from where its first line with more than spaces in it
    /// begins to say something. It is found by scalar: a mark that combines
    /// with a space stands alone without it.
    private static func firstLine(of text: String) -> Substring? {
        let scalars = text.unicodeScalars
        let start = scalars.firstIndex { !CharacterSet.whitespaces.contains($0) && !Character($0).isNewline }
        return start.map { Substring(scalars[$0...]) }
    }

    // MARK: - Kinds

    /// A color the way a stylesheet writes it. "#123" is more often the
    /// number of an issue than a color, so short hex made of digits alone
    /// does not count.
    static func isColor(_ text: String) -> Bool {
        guard text.count <= 64, ColorValue(text) != nil else { return false }
        if text.hasPrefix("#"), text.count <= 5, text.dropFirst().allSatisfy(\.isNumber) { return false }
        return true
    }

    /// One web address or app link and nothing else.
    static func isLink(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        if text.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\/].*/) != nil { return true }
        if text.wholeMatch(of: /mailto:[^@]+@[^@]+/.ignoresCase()) != nil { return true }
        return text.wholeMatch(of: /www\.[^.\/]+\.[^.\/].*/.ignoresCase()) != nil
    }
}

// MARK: - Wording

/// How the history words times.
public enum ClipboardFormat {
    /// How long ago, as briefly as a row has room for: "now", "6 min",
    /// "2 h", "3 d", and a date for what is older than a week.
    public static func age(of date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<86400: return "\(Int(seconds / 3600)) h"
        case ..<(7 * 86400): return "\(Int(seconds / 86400)) d"
        default:
            var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
            if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
                style = style.year()
            }
            style.locale = locale
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
    }

    /// The title of the part of the list a copy of `date` belongs to.
    public static func section(of date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        ClipSections(now: now, calendar: calendar).title(of: date)
    }
}

/// The parts a list of copies is divided into, by the day they were copied.
/// Made once for a list: where the days begin is the same for every row.
public struct ClipSections: Sendable {
    private let today: Date
    private let yesterday: Date
    private let week: Date
    private let month: Date

    public init(now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        func days(_ count: Int) -> Date {
            calendar.date(byAdding: .day, value: -count, to: today) ?? today.addingTimeInterval(Double(-count) * 86400)
        }
        self.today = today
        yesterday = days(1)
        week = days(7)
        month = days(30)
    }

    public func title(of date: Date) -> String {
        if date >= today { return "Today" }
        if date >= yesterday { return "Yesterday" }
        if date >= week { return "Previous 7 Days" }
        if date >= month { return "Previous 30 Days" }
        return "Older"
    }
}
