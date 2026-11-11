import Foundation

/// A named color. Results describe their look as data so that the UI layer,
/// and later scripted extensions, never have to pass real colors around.
public enum Tint: String, Sendable, Hashable, CaseIterable {
    case gray, red, orange, yellow, green, teal, blue, indigo, purple, pink
}

public indirect enum Icon: Sendable, Hashable {
    /// The Finder icon of the file, folder or application at `path`.
    case file(path: String)
    /// An SF Symbol drawn on a tinted tile.
    case symbol(String, tint: Tint)
    /// The icon of the website at `host`, see `Favicon.host(of:)`. `fallback`
    /// is drawn until the icon is there, and when the website has none.
    case favicon(host: String, fallback: Icon)
    /// A tile filled with one color: its red, green and blue in sRGB, and
    /// how see-through it is, each from 0 to 1.
    case swatch(red: Double, green: Double, blue: Double, alpha: Double)
}

/// An input a result asks for before it can run, shown inline in the search bar.
public struct Argument: Sendable, Hashable {
    public var name: String
    public var defaultValue: String?

    public init(name: String, defaultValue: String? = nil) {
        self.name = name
        self.defaultValue = defaultValue
    }

    public var isRequired: Bool { defaultValue == nil }
}

/// One row in the launcher.
public struct ResultItem: Identifiable, Sendable {
    /// Stable across launches. Usage history is keyed by it.
    public let id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon
    /// Short label shown at the trailing edge, such as "Application".
    public var kind: String
    /// Extra names the item should be found by.
    public var keywords: [String]
    public var arguments: [Argument]
    /// The first action runs on Return, the second on Command-Return.
    public var actions: [Action]

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: Icon,
        kind: String,
        keywords: [String] = [],
        arguments: [Argument] = [],
        actions: [Action]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.kind = kind
        self.keywords = keywords
        self.arguments = arguments
        self.actions = actions
    }
}

public struct ResultSection: Identifiable, Sendable {
    public var title: String
    public var items: [ResultItem]

    public init(title: String, items: [ResultItem]) {
        self.title = title
        self.items = items
    }

    public var id: String { title }
}

public struct InkyError: LocalizedError, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
