import AppKit

public struct KeyShortcut: Sendable, Hashable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// A lowercase character, or a named key such as "return" or "delete".
    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = [.command]) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The glyphs to draw as keycaps, modifiers first.
    public var symbols: [String] {
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        switch key {
        case "return": symbols.append("↵")
        case "delete": symbols.append("⌫")
        case "space": symbols.append("␣")
        default: symbols.append(key.uppercased())
        }
        return symbols
    }
}

/// What the launcher knows at the moment an action runs.
public struct ActionContext: Sendable {
    public var query: String
    /// One value per `ResultItem.arguments` entry, in order.
    public var arguments: [String]
    /// The app that was frontmost when the launcher opened.
    public var frontmostPID: pid_t?

    public init(query: String = "", arguments: [String] = [], frontmostPID: pid_t? = nil) {
        self.query = query
        self.arguments = arguments
        self.frontmostPID = frontmostPID
    }
}

/// Asked before an action that cannot be undone.
public struct Confirmation: Sendable, Hashable {
    public var title: String
    public var message: String
    public var confirmTitle: String

    public init(title: String, message: String, confirmTitle: String) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
    }
}

public struct Action: Identifiable, Sendable {
    public enum Behavior: Sendable {
        /// Close the launcher once the action succeeded.
        case dismiss
        /// Leave the launcher open, for actions that navigate inside it.
        case keepOpen
    }

    public typealias Handler = @MainActor @Sendable (ActionContext) async throws -> Void

    public var title: String
    /// SF Symbol name.
    public var symbol: String
    public var shortcut: KeyShortcut?
    public var behavior: Behavior
    /// Whether required arguments must be filled in before this action runs.
    public var usesArguments: Bool
    public var confirmation: Confirmation?
    public var perform: Handler

    public init(
        _ title: String,
        symbol: String,
        shortcut: KeyShortcut? = nil,
        behavior: Behavior = .dismiss,
        usesArguments: Bool = false,
        confirmation: Confirmation? = nil,
        perform: @escaping Handler
    ) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.behavior = behavior
        self.usesArguments = usesArguments
        self.confirmation = confirmation
        self.perform = perform
    }

    public var id: String { title }
}

// MARK: - Common actions

public extension Action {
    static func open(path: String, title: String = "Open") -> Action {
        Action(title, symbol: "arrow.up.forward.app") { _ in
            guard NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
                throw InkyError("Could not open \((path as NSString).lastPathComponent)")
            }
        }
    }

    static func showInFinder(path: String) -> Action {
        Action("Show in Finder", symbol: "folder") { _ in
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    static func copy(_ text: String, title: String, shortcut: KeyShortcut? = nil) -> Action {
        Action(title, symbol: "doc.on.doc", shortcut: shortcut) { _ in
            Pasteboard.copy(text)
        }
    }
}

public enum Pasteboard {
    @MainActor
    public static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    public static var text: String? {
        NSPasteboard.general.string(forType: .string)
    }
}
