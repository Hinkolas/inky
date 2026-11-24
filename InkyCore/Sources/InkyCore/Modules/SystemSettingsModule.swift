import AppKit

/// The panes of System Settings, each opened straight from the search.
@MainActor
public final class SystemSettingsModule: Module {
    public let id = "system-settings"
    public let info = ModuleInfo(
        title: "System Settings",
        summary: "Open a pane of System Settings, such as Wi‑Fi or Displays, right from the search.",
        icon: .symbol("gearshape.2.fill", tint: .gray)
    )
    public var onChange: (@MainActor () -> Void)?

    public static let kind = "Settings"
    /// Where every pane is found, shown after its name.
    public static let subtitle = "System Settings"

    private let scan: @Sendable () -> [SettingsPane]
    private let open: @MainActor (URL) -> Bool

    /// `scan` and `open` are for tests: where the panes come from, and what
    /// opens a link to one.
    public init(
        scan: @escaping @Sendable () -> [SettingsPane] = { SettingsPaneScanner.scan() },
        open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.scan = scan
        self.open = open
    }

    public static func itemID(for pane: SettingsPane) -> String {
        "settings:\(pane.id)"
    }

    public func candidates() async -> [ResultItem] {
        let panes = await Task.detached(priority: .userInitiated) { [scan] in scan() }.value
        return panes.map { pane in
            ResultItem(
                id: Self.itemID(for: pane),
                title: pane.name,
                subtitle: Self.subtitle,
                icon: pane.iconType.map { .type(identifier: $0) } ?? .file(path: pane.path),
                kind: Self.kind,
                keywords: pane.alternateNames,
                actions: [
                    Action("Open", symbol: "gearshape") { [open] _ in
                        switch pane.target {
                        case .link(let link):
                            guard let url = URL(string: link), open(url) else {
                                throw InkyError("System Settings could not open “\(pane.name)”")
                            }
                        case .file(let path):
                            try Opener.open(path: path)
                        }
                    },
                ]
            )
        }
    }
}
