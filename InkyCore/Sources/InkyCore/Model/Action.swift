import AppKit
import OSLog
import UniformTypeIdentifiers

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

    /// A lowercase character, or a named key: "return", "delete", "space",
    /// "tab", "escape", "up" or "down".
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
        case "tab": symbols.append("⇥")
        case "escape": symbols.append("esc")
        case "up": symbols.append("↑")
        case "down": symbols.append("↓")
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
    /// Whether the action destroys something, such as deleting it. It is
    /// drawn in red, and listed last.
    public var isDestructive: Bool
    public var perform: Handler

    public init(
        _ title: String,
        symbol: String,
        shortcut: KeyShortcut? = nil,
        behavior: Behavior = .dismiss,
        usesArguments: Bool = false,
        confirmation: Confirmation? = nil,
        isDestructive: Bool = false,
        perform: @escaping Handler
    ) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.behavior = behavior
        self.usesArguments = usesArguments
        self.confirmation = confirmation
        self.isDestructive = isDestructive
        self.perform = perform
    }

    public var id: String { title }
}

// MARK: - Common actions

public extension Action {
    static func open(path: String, title: String = "Open") -> Action {
        Action(title, symbol: "arrow.up.forward.app") { _ in
            try Opener.open(path: path)
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

public enum Opener {
    private static let log = Logger(subsystem: "io.github.hinkolas.inky", category: "open")

    /// Opens a file or folder, or launches an application.
    @MainActor
    public static func open(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: path) else {
            throw InkyError("“\(name)” no longer exists")
        }

        // Applications must be launched, not opened. Opening one like a
        // document makes macOS record the open on the bundle itself, which it
        // then blocks and reports as Inky trying to modify the app.
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .applicationBundle) ?? (url.pathExtension == "app") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    log.error("Could not launch \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } else if !NSWorkspace.shared.open(url) {
            throw InkyError("Could not open “\(name)”")
        }
    }
}

public enum Pasteboard {
    /// On the pasteboard next to what Inky copied itself, such as the result
    /// of a calculation. Inky takes keys without being the frontmost
    /// application, so its clipboard history would otherwise say the copy
    /// came from whatever application that is.
    public static let copiedByInky = NSPasteboard.PasteboardType("io.github.hinkolas.inky.copied")

    @MainActor
    public static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSPasteboard.general.setString("", forType: copiedByInky)
    }

    @MainActor
    public static var text: String? {
        NSPasteboard.general.string(forType: .string)
    }
}
