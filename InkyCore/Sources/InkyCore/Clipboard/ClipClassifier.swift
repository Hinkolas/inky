import Foundation

/// Sorts a copied text into what it looks like, and words what is shown of it.
public enum ClipClassifier {
    /// What `text` looks like: a color, a link, a path to something that is
    /// there, code, or text.
    public static func kind(of text: String, fileExists: (String) -> Bool) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 200, !trimmed.contains(where: \.isNewline) {
            if isColor(trimmed) { return .color }
            if isLink(trimmed) { return .link }
            // Much begins with a slash without being a path: "/help", the
            // path of a web address. What counts is that something is there.
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/"), trimmed.count > 1, fileExists(expandedPath(trimmed)) {
                return .path
            }
        }
        return looksLikeCode(trimmed) ? .code : .text
    }

    /// The path with the home folder written out.
    public static func expandedPath(_ text: String) -> String {
        (text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    /// One line to list the text by: its first line that says something,
    /// and a link without what every link begins with.
    public static func title(of text: String, kind: ClipKind) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var title = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

    /// Whether `text` reads as code. It errs on the side of text: a sentence
    /// with brackets in it is still a sentence.
    static func looksLikeCode(_ text: String) -> Bool {
        var marks = 0
        var visible = 0
        var lines = 1
        for character in text {
            if character.isNewline {
                lines += 1
            } else if !character.isWhitespace {
                visible += 1
                if structural.contains(character) { marks += 1 }
            }
        }
        guard visible > 0, marks >= 2 else { return false }
        let density = Double(marks) / Double(visible)

        // Several lines that are full of brackets need no further sign.
        if lines > 1, marks >= 4, density >= 0.08 { return true }
        guard density >= 0.03 else { return false }
        return operators.contains { text.contains($0) }
            || text.firstMatch(of: statement) != nil
    }

    private static let structural: Set<Character> = ["{", "}", "(", ")", "[", "]", ";", "=", "<", ">"]

    /// What prose does not write.
    private static let operators = [
        "=>", "->", "::", "==", "!=", "&&", "||", "+=", "();", "){", ") {", "</", "/>", "$(", "#!/", "\": ",
    ]

    /// A line that begins the way a statement does.
    nonisolated(unsafe) private static let statement =
        /(?m)^\s*(import|from|def|class|func|function|fn|const|let|var|struct|enum|interface|type|return|if|for|while|public|private|static|package|using|namespace|export|async|SELECT|INSERT|UPDATE|DELETE|CREATE|#include|@\w+)\b/
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
