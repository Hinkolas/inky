import Foundation

/// The user's quicklinks. Arguments in a link become inputs in the search bar.
@MainActor
public final class QuicklinkProvider: Provider {
    public let id = "quicklinks"
    public let info = ProviderInfo(
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
                id: "quicklink:\(quicklink.id.uuidString)",
                title: quicklink.name,
                subtitle: Self.summary(of: quicklink.link),
                icon: Self.icon(for: template),
                kind: "Quicklink",
                arguments: template.arguments,
                actions: actions(for: quicklink) { $0 }
            )
        }
    }

    /// The same quicklinks as in `candidates`, but these take what was typed
    /// as their argument instead of asking for one.
    public func fallbackResults(for query: String) -> [ResultItem] {
        store.fallbacks.map { quicklink in
            ResultItem(
                // Not the id it has as a candidate: both can be listed at once.
                id: "fallback:\(quicklink.id.uuidString)",
                title: quicklink.name,
                subtitle: Self.summary(of: quicklink.link),
                icon: Self.icon(for: quicklink.template),
                kind: "Quicklink",
                actions: actions(for: quicklink) { context in
                    var context = context
                    context.arguments = [context.query.trimmingCharacters(in: .whitespaces)]
                    return context
                }
            )
        }
    }

    /// `context` turns what the launcher knows into what the link is filled in from.
    private func actions(
        for quicklink: Quicklink,
        context: @escaping @Sendable (ActionContext) -> ActionContext
    ) -> [Action] {
        [
            Action("Open Quicklink", symbol: "arrow.up.forward", usesArguments: true) {
                try QuicklinkOpener.open(quicklink, context: context($0))
            },
            Action("Copy Link", symbol: "doc.on.doc", usesArguments: true) {
                Pasteboard.copy(QuicklinkOpener.resolve(quicklink, context: context($0)))
            },
            Action("Edit Quicklink", symbol: "pencil", shortcut: KeyShortcut("e"), behavior: .keepOpen) { [weak self] _ in
                self?.onEdit?(quicklink)
            },
        ]
    }

    /// Folders show their own icon; everything else gets the link tile.
    public static func icon(for template: LinkTemplate) -> Icon {
        if template.isFilePath, template.segments.count == 1 {
            let path = (template.source.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                return .file(path: path)
            }
        }
        return .symbol("link", tint: .purple)
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
