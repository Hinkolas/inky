import Foundation

/// The user's quicklinks. Arguments in a link become inputs in the search bar.
@MainActor
public final class QuicklinkModule: Module {
    public let id = "quicklinks"
    public let info = ModuleInfo(
        title: "Quicklinks",
        summary: "Open websites, folders and deeplinks, filling in arguments as you go.",
        icon: .symbol("link", tint: .purple)
    )
    public var onChange: (@MainActor () -> Void)?

    /// Set by the app to show its editor for a quicklink.
    public var onEdit: (@MainActor (Quicklink) -> Void)?

    private let store: QuicklinkStore

    public init(store: QuicklinkStore) {
        self.store = store
        store.onChange = { [weak self] in self?.onChange?() }
    }

    public func candidates() async -> [ResultItem] {
        store.quicklinks.map { quicklink in
            let template = quicklink.template
            return ResultItem(
                id: quicklink.itemID,
                title: quicklink.name,
                subtitle: Self.summary(of: quicklink.link),
                icon: Self.icon(for: template),
                kind: "Quicklink",
                arguments: template.arguments,
                actions: [
                    Action("Open Quicklink", symbol: "arrow.up.forward", usesArguments: true) {
                        try QuicklinkOpener.open(quicklink, context: $0)
                    },
                    Action("Copy Link", symbol: "doc.on.doc", usesArguments: true) {
                        Pasteboard.copy(QuicklinkOpener.resolve(quicklink, context: $0))
                    },
                    Action("Edit Quicklink", symbol: "pencil", shortcut: KeyShortcut("e"), behavior: .keepOpen) { [weak self] _ in
                        self?.onEdit?(quicklink)
                    },
                ]
            )
        }
    }

    /// Folders show their own icon and websites theirs; everything else gets
    /// the link tile.
    public static func icon(for template: LinkTemplate) -> Icon {
        if template.isFilePath, template.segments.count == 1 {
            let path = (template.source.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                return .file(path: path)
            }
        }
        let tile = Icon.symbol("link", tint: .purple)
        if let host = Favicon.host(of: template.source) {
            return .favicon(host: host, fallback: tile)
        }
        return tile
    }

    /// The site or folder a link goes to, without the noise.
    public static func summary(of link: String) -> String {
        var text = link.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/") || text.hasPrefix("~") { return text }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        if text.hasPrefix("www.") {
            text = String(text.dropFirst(4))
        }
        return String(text.prefix { $0 != "/" && $0 != "?" && $0 != "{" })
    }
}
