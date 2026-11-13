import Foundation

/// A file or folder the Spotlight index knows, with what the index says
/// about it. Nothing here is read from the file itself.
public struct FileHit: Identifiable, Sendable, Hashable {
    public var path: String
    public var name: String
    /// What Finder calls it: "PNG image".
    public var kind: String?
    /// Its uniform type identifier: "public.png".
    public var contentType: String?
    public var size: Int64?
    public var created: Date?
    public var modified: Date?
    public var lastOpened: Date?
    /// Of an image or a movie.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Of a recording or a movie, in seconds.
    public var duration: TimeInterval?
    /// Of a document that has pages.
    public var pages: Int?

    public init(
        path: String,
        name: String,
        kind: String? = nil,
        contentType: String? = nil,
        size: Int64? = nil,
        created: Date? = nil,
        modified: Date? = nil,
        lastOpened: Date? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        duration: TimeInterval? = nil,
        pages: Int? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.contentType = contentType
        self.size = size
        self.created = created
        self.modified = modified
        self.lastOpened = lastOpened
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.pages = pages
    }

    public var id: String { path }

    public var isFolder: Bool { contentType == "public.folder" }

    /// The folder it is in, with the home folder as a tilde.
    public var folder: String {
        ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }
}

/// A kind of file a search can be narrowed down to.
public enum FileFilter: String, CaseIterable, Sendable {
    case all, folders, documents, images, videos, audio, code

    public var title: String {
        switch self {
        case .all: "All Types"
        case .folders: "Folders"
        case .documents: "Documents"
        case .images: "Images"
        case .videos: "Videos"
        case .audio: "Audio"
        case .code: "Code"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .folders: "folder"
        case .documents: "doc.text"
        case .images: "photo"
        case .videos: "film"
        case .audio: "waveform"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// What Spotlight is asked for, by the types a file conforms to.
    var expression: String? {
        let tree = "kMDItemContentTypeTree"
        return switch self {
        case .all: nil
        case .folders: "kMDItemContentType == \"public.folder\""
        // What is written to be read: PDFs, what word processors and
        // spreadsheets save, and text that is not source code.
        case .documents:
            "(\(tree) == \"public.composite-content\" || \(tree) == \"public.presentation\""
                + " || \(tree) == \"public.spreadsheet\""
                + " || (\(tree) == \"public.text\" && \(tree) != \"public.source-code\"))"
        case .images: "\(tree) == \"public.image\""
        case .videos: "\(tree) == \"public.movie\""
        case .audio: "\(tree) == \"public.audio\""
        case .code: "\(tree) == \"public.source-code\""
        }
    }
}

/// What is looked for: files by words of their name, or, with nothing
/// typed, the ones that were opened lately.
public struct FileQuery: Sendable, Equatable {
    public var text: String
    public var filter: FileFilter

    public init(text: String, filter: FileFilter = .all) {
        self.text = text
        self.filter = filter
    }

    /// How far back "lately" goes.
    static let recentDays = 30

    var words: [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether nothing is typed, and the files opened lately are meant.
    public var isRecents: Bool { words.isEmpty }

    /// The query in Spotlight's own language.
    ///
    /// Every word has to begin a word of the name, in any order, ignoring
    /// case and diacritics: "watch fold" finds "FolderWatcher.swift".
    public var expression: String {
        var parts = words.map { word in
            let escaped = word
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "*", with: "\\*")
            return "kMDItemDisplayName == \"\(escaped)*\"cdw"
        }
        if parts.isEmpty {
            parts.append("kMDItemLastUsedDate >= $time.now(-\(Self.recentDays * 86400))")
        }
        if let type = filter.expression {
            parts.append(type)
        }
        return parts.joined(separator: " && ")
    }
}

/// Looks files up in the Spotlight index.
public enum FileSearch {
    /// Folders full of files nobody opens by hand.
    static let noise = ["/node_modules/", "/go/pkg/mod/", "/DerivedData/", "/Pods/", "/__pycache__/"]

    /// The best `limit` files for `query`, best first.
    ///
    /// - Parameters:
    ///   - scopes: The folders to look in. Nil is the user's home folder.
    ///   - gatherLimit: How many files are taken from Spotlight to rank. It
    ///     stops broad queries from gathering half the disk.
    ///
    /// The search runs away from the thread it is asked on. Cancelling the
    /// task stops it, and it then finds nothing.
    public static func run(
        _ query: FileQuery,
        in scopes: [String]? = nil,
        limit: Int,
        gatherLimit: Int = 400
    ) async -> [FileHit] {
        await SpotlightSearch(query: query, scopes: scopes, limit: limit, gatherLimit: gatherLimit).run()
    }

    /// Whether a path is worth listing: not an application, which has a
    /// module of its own, and not in a folder that is hidden, the user's
    /// Library, or full of what tools put there.
    static func lists(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        !path.hasPrefix(home + "/Library/") && !path.hasSuffix(".app") && !path.contains("/.")
            && !noise.contains(where: path.contains)
    }

    /// Orders what Spotlight found, which it lists most recently used first.
    /// A better match of the name outranks recency, but only just, so both
    /// signals count. Returns positions in `names`, best first.
    static func ranking(of names: [String], for text: String) -> [Int] {
        let pattern = FuzzyMatcher.Pattern(text)
        // Words may be typed in another order than the name has them, and
        // then do not match as a whole. Each is matched for itself as well.
        let words = text.split(whereSeparator: \.isWhitespace).map { FuzzyMatcher.Pattern(String($0)) }
        return names.enumerated()
            .map { offset, name -> (offset: Int, score: Double) in
                let target = FuzzyMatcher.Target(name)
                var match = FuzzyMatcher.score(pattern, in: target) ?? 0
                if match == 0, words.count > 1 {
                    let scores = words.compactMap { FuzzyMatcher.score($0, in: target) }
                    if scores.count == words.count {
                        match = scores.reduce(0, +) / Double(words.count) * 0.9
                    }
                }
                return (offset, match - Double(offset) * 0.002)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.offset)
    }
}

/// One Spotlight query, bridged to async/await.
///
/// Nothing of it happens on the main thread. Asking Spotlight for what it
/// knows of a file takes a third of a millisecond a file, and a search
/// lists a hundred of them: on the main thread that is a launcher that
/// stands still. The query runs on a queue of its own, and everything this
/// type keeps is only touched there.
private final class SpotlightSearch: @unchecked Sendable {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.github.hinkolas.inky.file-search"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// What is asked about a file that is listed, in one go. Its path is
    /// asked for by itself: asked for along with the rest, a file that has
    /// none brings Foundation down.
    private static let details: [String] = [
        kMDItemKind as String, NSMetadataItemContentTypeKey, NSMetadataItemFSSizeKey,
        NSMetadataItemFSCreationDateKey, NSMetadataItemFSContentChangeDateKey, kMDItemLastUsedDate as String,
        kMDItemPixelWidth as String, kMDItemPixelHeight as String, kMDItemDurationSeconds as String,
        kMDItemNumberOfPages as String,
    ]

    private let asked: FileQuery
    private let limit: Int
    private let gatherLimit: Int
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var continuation: CheckedContinuation<[FileHit], Never>?
    private var isCancelled = false

    init(query asked: FileQuery, scopes: [String]?, limit: Int, gatherLimit: Int) {
        self.asked = asked
        self.limit = limit
        // The files opened lately are few enough to gather them all, and
        // stopping early could leave out the latest of them.
        self.gatherLimit = asked.isRecents ? .max : gatherLimit
        query.predicate = NSPredicate(fromMetadataQueryString: asked.expression)
        query.searchScopes = scopes ?? [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: kMDItemLastUsedDate as String, ascending: false)]
        // The names come with the results, all at once. They are what the
        // results are ranked by, and asked for file by file they would take
        // a thousand times as long.
        query.valueListAttributes = [NSMetadataItemDisplayNameKey]
        query.operationQueue = Self.queue
    }

    func run() async -> [FileHit] {
        guard !Task.isCancelled, query.predicate != nil else { return [] }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.queue.addOperation { [self] in
                    self.continuation = continuation
                    // Cancelled before it began.
                    guard !isCancelled else { return finish(collecting: false) }
                    observe(.NSMetadataQueryDidFinishGathering) { search in
                        search.finish(collecting: true)
                    }
                    observe(.NSMetadataQueryGatheringProgress) { search in
                        if search.query.resultCount >= search.gatherLimit {
                            search.finish(collecting: true)
                        }
                    }
                    if !query.start() {
                        finish(collecting: false)
                    }
                }
            }
        } onCancel: {
            Self.queue.addOperation { [self] in
                isCancelled = true
                finish(collecting: false)
            }
        }
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @Sendable (SpotlightSearch) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: Self.queue) { [self] _ in
            handler(self)
        })
    }

    private func finish(collecting: Bool) {
        guard let continuation else { return }
        self.continuation = nil

        query.disableUpdates()
        let hits = collecting ? collect() : []
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []

        continuation.resume(returning: hits)
    }

    /// Reads the results while the query still holds them: ranks them by
    /// their names, then asks about the best of them until enough are worth
    /// listing.
    private func collect() -> [FileHit] {
        let count = min(query.resultCount, gatherLimit)
        // The files opened lately come in the order they are listed in.
        let order = asked.isRecents
            ? Array(0..<count)
            : FileSearch.ranking(
                of: (0..<count).map { query.value(ofAttribute: NSMetadataItemDisplayNameKey, forResultAt: $0) as? String ?? "" },
                for: asked.text
            )

        var hits: [FileHit] = []
        for index in order {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  FileSearch.lists(path)
            else { continue }
            let values = item.values(forAttributes: Self.details) ?? [:]
            func number(_ key: CFString) -> NSNumber? { values[key as String] as? NSNumber }
            hits.append(FileHit(
                path: path,
                name: query.value(ofAttribute: NSMetadataItemDisplayNameKey, forResultAt: index) as? String
                    ?? (path as NSString).lastPathComponent,
                kind: values[kMDItemKind as String] as? String,
                contentType: values[NSMetadataItemContentTypeKey] as? String,
                size: (values[NSMetadataItemFSSizeKey] as? NSNumber)?.int64Value,
                created: values[NSMetadataItemFSCreationDateKey] as? Date,
                modified: values[NSMetadataItemFSContentChangeDateKey] as? Date,
                lastOpened: values[kMDItemLastUsedDate as String] as? Date,
                pixelWidth: number(kMDItemPixelWidth)?.intValue,
                pixelHeight: number(kMDItemPixelHeight)?.intValue,
                duration: number(kMDItemDurationSeconds)?.doubleValue,
                pages: number(kMDItemNumberOfPages)?.intValue
            ))
            if hits.count == limit { break }
        }
        return hits
    }
}

/// The beginning of a file, if it reads as text.
public enum FileExcerpt {
    /// How much of a file is read to show its beginning.
    public static let byteLimit = 16 * 1024

    /// The first lines of `data`, the beginning of a file, or nil if it is
    /// not text: it holds what text does not, or is not UTF-8.
    public static func text(from data: Data, maxLines: Int = 60, maxCharacters: Int = 4000) -> String? {
        guard !data.isEmpty, !data.contains(0) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        // Where the file was cut, a character may have been cut in two.
        // More than that, and it is something else.
        let broken = text.unicodeScalars.reduce(0) { $1 == "\u{FFFD}" ? $0 + 1 : $0 }
        guard broken <= 1 else { return nil }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .split(separator: "\n", maxSplits: maxLines, omittingEmptySubsequences: false)
            .prefix(maxLines)
        return String(lines.joined(separator: "\n").prefix(maxCharacters))
    }
}
