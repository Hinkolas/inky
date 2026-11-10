import Foundation

/// Files and folders in the user's home folder, found through the Spotlight index.
@MainActor
public final class FileProvider: Provider {
    public let id = "files"
    public let info = ProviderInfo(
        title: "File Search",
        summary: "Find files and folders by name using the Spotlight index.",
        icon: .symbol("doc.text.magnifyingglass", tint: .teal)
    )
    public var onChange: (@MainActor () -> Void)?

    public var maxResults = 8
    /// Shorter queries match too much of the disk to be useful.
    public var minimumQueryLength = 3

    public init() {}

    public func deferredResults(for query: String) async -> ResultSection? {
        guard query.count >= minimumQueryLength else { return nil }
        let hits = await SpotlightSearch(text: query).run()
        guard !Task.isCancelled else { return nil }

        // Spotlight returns most recently used first. Let a better name match
        // outrank recency, but only just, so both signals count.
        let pattern = FuzzyMatcher.Pattern(query)
        let ranked = hits.enumerated()
            .map { offset, hit in
                let match = FuzzyMatcher.score(pattern, in: FuzzyMatcher.Target(hit.name)) ?? 0
                return (hit: hit, score: match - Double(offset) * 0.002)
            }
            .sorted { $0.score > $1.score }
            .prefix(maxResults)

        let home = NSHomeDirectory()
        let items = ranked.map { entry -> ResultItem in
            let hit = entry.hit
            var folder = (hit.path as NSString).deletingLastPathComponent
            if folder.hasPrefix(home) {
                folder = "~" + folder.dropFirst(home.count)
            }
            return ResultItem(
                id: "file:\(hit.path)",
                title: hit.name,
                subtitle: folder,
                icon: .file(path: hit.path),
                kind: hit.kind ?? "File",
                actions: [
                    .open(path: hit.path),
                    .showInFinder(path: hit.path),
                    .copy(hit.path, title: "Copy Path", shortcut: KeyShortcut("c", [.command, .shift])),
                ]
            )
        }
        return ResultSection(title: "Files", items: Array(items))
    }
}

private struct SpotlightHit: Sendable {
    var path: String
    var name: String
    var kind: String?
}

/// One Spotlight query, bridged to async/await. Cancelling the task stops it.
@MainActor
private final class SpotlightSearch {
    /// Enough to rank from. Stops broad queries from gathering half the disk.
    private static let gatherLimit = 400

    /// Folders full of files nobody opens by hand.
    private static let noise = ["/node_modules/", "/go/pkg/mod/", "/DerivedData/", "/Pods/", "/__pycache__/"]

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var continuation: CheckedContinuation<[SpotlightHit], Never>?

    init(text: String) {
        // Match the start of any word in the name, ignoring case and diacritics.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
        query.predicate = NSPredicate(fromMetadataQueryString: "kMDItemDisplayName == \"\(escaped)*\"cdw")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: kMDItemLastUsedDate as String, ascending: false)]
    }

    func run() async -> [SpotlightHit] {
        guard !Task.isCancelled else { return [] }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                observe(.NSMetadataQueryDidFinishGathering) { search in
                    search.finish(collecting: true)
                }
                observe(.NSMetadataQueryGatheringProgress) { search in
                    if search.query.resultCount >= Self.gatherLimit {
                        search.finish(collecting: true)
                    }
                }
                if !query.start() {
                    finish(collecting: false)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(collecting: false) }
        }
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (SpotlightSearch) -> Void) {
        let observer = NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { handler(self) }
            }
        }
        observers.append(observer)
    }

    private func finish(collecting: Bool) {
        guard let continuation else { return }
        self.continuation = nil

        query.disableUpdates()
        var hits: [SpotlightHit] = []
        if collecting {
            let library = NSHomeDirectory() + "/Library/"
            for index in 0..<min(query.resultCount, Self.gatherLimit) {
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      !path.hasPrefix(library), !path.hasSuffix(".app"), !path.contains("/."),
                      !Self.noise.contains(where: path.contains)
                else { continue }
                hits.append(SpotlightHit(
                    path: path,
                    name: item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
                        ?? (path as NSString).lastPathComponent,
                    kind: item.value(forAttribute: kMDItemKind as String) as? String
                ))
            }
        }
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []

        continuation.resume(returning: hits)
    }
}
