import Foundation

/// Files and folders in the user's home folder, found through the Spotlight index.
///
/// The search lists a few of them below its other results. The command
/// "Search Files" shows more, with a preview, on a screen of its own.
@MainActor
public final class FileModule: Module {
    public static let title = "Search Files"
    public static let icon = Icon.symbol("doc.text.magnifyingglass", tint: .teal)
    /// The id of the command that shows the screen.
    public static let searchID = "files:search"

    public let id = "files"
    public let info = ModuleInfo(
        title: "File Search",
        summary: "Find files and folders by name using the Spotlight index.",
        icon: FileModule.icon
    )
    public var onChange: (@MainActor () -> Void)?

    /// Set by the app to show the screen, with what is to be searched for.
    public var onOpen: (@MainActor (String) -> Void)?

    public var maxResults = 8
    /// Shorter queries match too much of the disk to be useful.
    public var minimumQueryLength = 3
    /// The folders that are searched. Nil is the user's home folder.
    public var scopes: [String]?

    public init() {}

    public func candidates() async -> [ResultItem] {
        [
            ResultItem(
                id: Self.searchID,
                title: Self.title,
                icon: Self.icon,
                kind: "Command",
                keywords: ["Find Files", "File Search", "Recent Files", "Folders", "Documents"],
                // What to search for can be typed along, and being the one
                // argument, lets the command be chosen as a fallback.
                arguments: [Argument(name: "Name", defaultValue: "")],
                actions: [
                    Action("Open", symbol: "doc.text.magnifyingglass", behavior: .keepOpen, usesArguments: true) { [weak self] context in
                        self?.onOpen?(context.arguments.first ?? "")
                    },
                ]
            ),
        ]
    }

    public func deferredResults(for query: String) async -> ResultSection? {
        guard query.count >= minimumQueryLength else { return nil }
        let hits = await FileSearch.run(FileQuery(text: query), in: scopes, limit: maxResults)
        guard !Task.isCancelled else { return nil }

        let items = hits.map { hit in
            ResultItem(
                id: "file:\(hit.path)",
                title: hit.name,
                subtitle: hit.folder,
                icon: .file(path: hit.path),
                kind: hit.kind ?? "File",
                actions: [
                    .open(path: hit.path),
                    .showInFinder(path: hit.path),
                    .copy(hit.path, title: "Copy Path", shortcut: KeyShortcut("c", [.command, .shift])),
                ]
            )
        }
        return ResultSection(title: "Files", items: items)
    }
}
