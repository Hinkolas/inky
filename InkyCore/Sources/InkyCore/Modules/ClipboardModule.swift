import Foundation

/// What was copied, kept to be found and pasted again.
@MainActor
public final class ClipboardModule: Module {
    public static let title = "Clipboard History"
    public static let icon = Icon.symbol("clipboard.fill", tint: .teal)

    public let id = "clipboard"
    public let info = ModuleInfo(
        title: ClipboardModule.title,
        summary: "Keeps what you copy, so you can find it and paste it again.",
        icon: ClipboardModule.icon
    )
    public var onChange: (@MainActor () -> Void)?

    /// Set by the app to show the history.
    public var onOpen: (@MainActor () -> Void)?
    /// Set by the app to delete the history, apart from what is pinned.
    public var onClear: (@MainActor () -> Void)?

    public init() {}

    public func candidates() async -> [ResultItem] {
        [
            ResultItem(
                id: "clipboard:history",
                title: Self.title,
                icon: Self.icon,
                kind: "Command",
                keywords: ["Paste", "Copied", "Pasteboard", "Clips"],
                actions: [
                    Action("Open", symbol: "clipboard", behavior: .keepOpen) { [weak self] _ in
                        self?.onOpen?()
                    },
                ]
            ),
            ResultItem(
                id: "clipboard:clear",
                title: "Clear Clipboard History",
                icon: .symbol("trash.fill", tint: .teal),
                kind: "Command",
                keywords: ["Delete Clipboard History", "Empty Clipboard History"],
                actions: [
                    Action(
                        "Clear History",
                        symbol: "trash",
                        confirmation: Confirmation(
                            title: "Clear the clipboard history?",
                            message: "Everything Inky kept of what you copied is deleted. What you pinned stays.",
                            confirmTitle: "Clear History"
                        ),
                        isDestructive: true
                    ) { [weak self] _ in
                        self?.onClear?()
                    },
                ]
            ),
        ]
    }
}
