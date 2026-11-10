import Foundation

/// A quicklink's link, parsed into literal text and placeholders.
///
/// Placeholders are written in braces and filled in when the link opens:
///
///     https://example.com/search?q={argument name="Query"}
///     https://translate.example.com/?text={clipboard | trim}
///
/// Supported: `{argument}`, `{clipboard}`, `{selection}`, `{date}`, `{time}`,
/// `{datetime}`, `{day}` and `{uuid}`. Modifiers follow a `|` and apply in
/// order: `uppercase`, `lowercase`, `trim`, `percent-encode`, `raw`.
/// Anything else in braces is left alone.
public struct LinkTemplate: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case argument, clipboard, selection, date, time, datetime, day, uuid
    }

    public enum Modifier: String, Sendable {
        case uppercase, lowercase, trim
        case percentEncode = "percent-encode"
        /// Insert the value as is, even in a web link.
        case raw
    }

    public struct Placeholder: Sendable, Equatable {
        public var kind: Kind
        public var attributes: [String: String]
        public var modifiers: [Modifier]
        /// For arguments: the position in `LinkTemplate.arguments`.
        public var argumentIndex: Int?
    }

    public enum Segment: Sendable, Equatable {
        case text(String)
        case placeholder(Placeholder)
    }

    /// What placeholders resolve to.
    public struct Values: Sendable {
        public var arguments: [String]
        public var clipboard: String
        public var selection: String
        public var date: Date
        public var locale: Locale

        public init(
            arguments: [String] = [],
            clipboard: String = "",
            selection: String = "",
            date: Date = .now,
            locale: Locale = .current
        ) {
            self.arguments = arguments
            self.clipboard = clipboard
            self.selection = selection
            self.date = date
            self.locale = locale
        }
    }

    public let source: String
    public let segments: [Segment]
    /// The distinct arguments the link asks for, in order of appearance.
    public let arguments: [Argument]

    public init(_ source: String) {
        self.source = source

        var segments: [Segment] = []
        var arguments: [Argument] = []
        var text = ""
        var rest = Substring(source)

        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let body = rest[rest.index(after: open)..<close]
            if var placeholder = Self.parse(body) {
                text += rest[..<open]
                if !text.isEmpty {
                    segments.append(.text(text))
                    text = ""
                }
                if placeholder.kind == .argument {
                    // Arguments with the same name share one input.
                    let name = placeholder.attributes["name"]
                    if let name, let existing = arguments.firstIndex(where: { $0.name == name }) {
                        placeholder.argumentIndex = existing
                    } else {
                        placeholder.argumentIndex = arguments.count
                        arguments.append(Argument(
                            name: name ?? "Argument",
                            defaultValue: placeholder.attributes["default"]
                        ))
                    }
                }
                segments.append(.placeholder(placeholder))
            } else {
                text += rest[...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        text += rest
        if !text.isEmpty {
            segments.append(.text(text))
        }

        self.segments = segments
        self.arguments = arguments
    }

    public func uses(_ kind: Kind) -> Bool {
        segments.contains { segment in
            if case .placeholder(let placeholder) = segment { return placeholder.kind == kind }
            return false
        }
    }

    /// Whether the link points at a file or folder rather than a URL.
    public var isFilePath: Bool {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    /// Fills in the placeholders. Values are percent-encoded so they are safe
    /// inside a URL, unless the link is a file path or the placeholder says `raw`.
    public func resolve(_ values: Values) -> String {
        var result = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                result += text
            case .placeholder(let placeholder):
                var value = Self.value(of: placeholder, values)
                var encode = !isFilePath
                for modifier in placeholder.modifiers {
                    switch modifier {
                    case .uppercase: value = value.uppercased()
                    case .lowercase: value = value.lowercased()
                    case .trim: value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    case .percentEncode: encode = true
                    case .raw: encode = false
                    }
                }
                result += encode ? Self.percentEncode(value) : value
            }
        }
        return result
    }

    // MARK: - Private

    private static func parse(_ body: Substring) -> Placeholder? {
        let parts = body.split(separator: "|", omittingEmptySubsequences: false)
        guard let head = parts.first?.trimmingCharacters(in: .whitespaces) else { return nil }

        let name = head.prefix { !$0.isWhitespace }
        guard let kind = Kind(rawValue: name.lowercased()) else { return nil }

        var attributes: [String: String] = [:]
        for match in head.dropFirst(name.count).matches(of: /([A-Za-z-]+)\s*=\s*"([^"]*)"/) {
            attributes[String(match.1).lowercased()] = String(match.2)
        }

        let modifiers = parts.dropFirst().compactMap {
            Modifier(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return Placeholder(kind: kind, attributes: attributes, modifiers: modifiers)
    }

    private static func value(of placeholder: Placeholder, _ values: Values) -> String {
        switch placeholder.kind {
        case .argument:
            let index = placeholder.argumentIndex ?? 0
            let typed = index < values.arguments.count ? values.arguments[index] : ""
            return typed.isEmpty ? placeholder.attributes["default"] ?? "" : typed
        case .clipboard:
            return values.clipboard
        case .selection:
            return values.selection
        case .uuid:
            return UUID().uuidString
        case .date, .time, .datetime, .day:
            let formatter = DateFormatter()
            formatter.locale = values.locale
            if let format = placeholder.attributes["format"] {
                formatter.dateFormat = format
            } else {
                switch placeholder.kind {
                case .date: formatter.dateStyle = .medium
                case .time: formatter.timeStyle = .short
                case .day: formatter.dateFormat = "EEEE"
                default:
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                }
            }
            return formatter.string(from: values.date)
        }
    }

    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
