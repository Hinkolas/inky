import CryptoKit
import Foundation

/// What a copy is, as far as showing it and finding it again goes.
public enum ClipKind: String, Sendable, CaseIterable {
    case text, path, link, color, image, file

    public var title: String {
        switch self {
        case .text: "Text"
        case .path: "Path"
        case .link: "Link"
        case .color: "Color"
        case .image: "Image"
        case .file: "File"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .text: "textformat"
        case .path: "folder"
        case .link: "link"
        case .color: "circle.lefthalf.filled"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

/// One entry of the clipboard history, without what was copied: enough to
/// list it. The content is read when it is looked at or pasted.
public struct Clip: Identifiable, Sendable, Hashable {
    public let id: Int64
    public var kind: ClipKind
    /// One line that says what it is: the first line of a text, a file's name.
    public var title: String
    /// What the user called it. Only pinned entries have names.
    public var name: String?
    /// The application it was copied in.
    public var sourceName: String?
    public var sourceBundleID: String?
    public var firstCopied: Date
    /// The same thing copied again is the same entry, copied later.
    public var lastCopied: Date
    public var copies: Int
    /// When it was pinned, if it is.
    public var pinned: Date?
    public var byteCount: Int
    /// Of an image, in pixels.
    public var width: Int?
    public var height: Int?
    /// Where an image is kept, as a file name in the store's folder of
    /// images. For a file or a path, where that is on disk.
    public var location: String?
    /// How many files were copied together.
    public var items: Int
    /// Whether it was copied with formatting, which pasting keeps.
    public var hasFormatting: Bool
    /// Whether the application it came from marked it as a secret, as
    /// password managers do. Recorded, and not acted on yet.
    public var isConcealed: Bool

    public var isPinned: Bool { pinned != nil }

    /// What a row calls it.
    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return title
    }
}

/// Something that was copied, on its way into the history.
public struct ClipCapture: Sendable {
    public var kind: ClipKind
    public var title: String
    /// What was copied, where that is text. For files, their paths, one a line.
    public var text: String?
    /// The same text in the other ways the application offered it, such as
    /// RTF, by the name of the pasteboard type.
    public var flavors: [String: Data] = [:]
    /// An image as it was offered, with the type it was offered as.
    public var image: Data?
    public var imageType: String?
    public var location: String?
    public var items = 1
    public var sourceName: String?
    public var sourceBundleID: String?
    public var isConcealed = false
    public var date = Date.now

    /// A text that was copied, sorted into what it looks like. Nil for one
    /// that is empty.
    public static func text(
        _ text: String,
        flavors: [String: Data] = [:],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ClipCapture? {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        let kind = ClipClassifier.kind(of: text, fileExists: fileExists)
        var capture = ClipCapture(kind: kind, title: ClipClassifier.title(of: text, kind: kind), text: text)
        switch kind {
        case .text:
            capture.flavors = flavors
        case .path:
            capture.location = ClipClassifier.expandedPath(text)
        default:
            // A link or a color is pasted as what it says.
            break
        }
        return capture
    }

    /// An image that was copied, as `type` says it is encoded.
    public static func image(_ data: Data, type: String, from source: String? = nil) -> ClipCapture {
        ClipCapture(
            kind: .image,
            title: source.map { "Image from \($0)" } ?? "Image",
            image: data,
            imageType: type
        )
    }

    /// Files that were copied, as in Finder. Nil if there are none.
    public static func files(_ paths: [String]) -> ClipCapture? {
        guard let first = paths.first else { return nil }
        let name = (first as NSString).lastPathComponent
        return ClipCapture(
            kind: .file,
            title: paths.count == 1 ? name : "\(name) and \(paths.count - 1) more",
            text: paths.joined(separator: "\n"),
            location: first,
            items: paths.count
        )
    }

    /// What tells one copy from another. The same text is the same entry
    /// however it was sorted, and whatever formatting came with it.
    var hash: Data {
        var hasher = SHA256()
        if let image {
            hasher.update(data: Data("image:".utf8))
            hasher.update(data: image)
        } else {
            hasher.update(data: Data((kind == .file ? "files:" : "text:").utf8))
            hasher.update(data: Data((text ?? "").utf8))
        }
        return Data(hasher.finalize())
    }

    var byteCount: Int {
        image?.count ?? (text ?? "").utf8.count + flavors.values.reduce(0) { $0 + $1.count }
    }
}

/// What an entry holds, as far as it is shown.
public struct ClipContent: Sendable, Equatable {
    public var id: Int64
    /// The beginning of the text. Nil for an image.
    public var text: String?
    /// Whether there is more of it than `text` holds.
    public var isTruncated: Bool
    public var characters: Int
    public var lines: Int
}

/// What an entry holds, to put it back on the pasteboard.
public struct ClipPayload: Sendable {
    public var kind: ClipKind
    public var text: String?
    public var flavors: [String: Data]
    /// Where an image is, and the type it is kept as.
    public var imageURL: URL?
    public var imageType: String?
    /// Whether a password manager marked it as confidential. Put back on the
    /// pasteboard, it says so again, so that other clipboard managers leave
    /// it out as they did the first time.
    public var isConcealed = false
}

// MARK: - Narrowing down

/// A choice of kinds, as the history is narrowed down by.
public enum ClipFilter: String, Sendable, CaseIterable {
    case all, text, links, images, colors, files

    public var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .links: "Links"
        case .images: "Images"
        case .colors: "Colors"
        case .files: "Files"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .all: "clipboard"
        case .text: ClipKind.text.symbol
        case .links: ClipKind.link.symbol
        case .images: ClipKind.image.symbol
        case .colors: ClipKind.color.symbol
        case .files: ClipKind.file.symbol
        }
    }

    /// Nil for every kind.
    public var kinds: [ClipKind]? {
        switch self {
        case .all: nil
        case .text: [.text, .path]
        case .links: [.link]
        case .images: [.image]
        case .colors: [.color]
        case .files: [.file]
        }
    }

    public func includes(_ kind: ClipKind) -> Bool {
        kinds?.contains(kind) ?? true
    }
}

/// How far back the history is looked at.
public enum ClipRange: String, Sendable, CaseIterable, Identifiable {
    case all, hour, day, week, month

    public var id: Self { self }

    public var title: String {
        switch self {
        case .all: "Any time"
        case .hour: "Last hour"
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }

    /// The moment it starts at. Nil for all of it.
    public func start(from now: Date = .now) -> Date? {
        switch self {
        case .all: nil
        case .hour: now.addingTimeInterval(-3600)
        case .day: now.addingTimeInterval(-86400)
        case .week: now.addingTimeInterval(-7 * 86400)
        case .month: now.addingTimeInterval(-30 * 86400)
        }
    }
}

/// What the history is asked for.
public struct ClipQuery: Sendable, Equatable {
    /// Words that all have to be in an entry, in any order and anywhere in it.
    public var text: String
    public var filter: ClipFilter
    /// Only what was copied since. Pinned entries are listed whenever they
    /// were copied.
    public var since: Date?

    public init(text: String = "", filter: ClipFilter = .all, since: Date? = nil) {
        self.text = text
        self.filter = filter
        self.since = since
    }
}

/// The history as a screen shows it at first: what is pinned, the newest
/// entries, and how many there are of each kind.
public struct ClipSnapshot: Sendable {
    /// Everything that is pinned, in the order it was pinned.
    public var pins: [Clip] = []
    /// The pinned entries the query finds.
    public var pinned: [Clip] = []
    /// The newest entries the query finds that are not pinned.
    public var clips: [Clip] = []
    /// Whether the query finds more than `clips` holds.
    public var hasMore = false
    /// How many entries there are of each kind, since the query's start.
    public var counts: [ClipKind: Int] = [:]

    public init() {}

    public var total: Int { counts.values.reduce(0, +) }

    public func count(_ filter: ClipFilter) -> Int {
        counts.reduce(0) { $0 + (filter.includes($1.key) ? $1.value : 0) }
    }
}

/// How much the history holds.
public struct ClipboardStatistics: Sendable, Equatable {
    public var entries = 0
    public var pinned = 0
    /// On disk, images included.
    public var bytes: Int64 = 0

    public init() {}
}

// MARK: - Keeping

/// How long a copy stays in the history.
public enum ClipboardRetention: String, Sendable, CaseIterable, Identifiable {
    case day, week, month, threeMonths, sixMonths, year, forever

    public var id: Self { self }

    public var title: String {
        switch self {
        case .day: "1 day"
        case .week: "7 days"
        case .month: "30 days"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .year: "1 year"
        case .forever: "Forever"
        }
    }

    /// What was copied before this has been kept long enough. Nil if
    /// nothing ever has.
    public func cutoff(from now: Date = .now, calendar: Calendar = .current) -> Date? {
        let span: DateComponents? = switch self {
        case .day: DateComponents(day: -1)
        case .week: DateComponents(day: -7)
        case .month: DateComponents(day: -30)
        case .threeMonths: DateComponents(month: -3)
        case .sixMonths: DateComponents(month: -6)
        case .year: DateComponents(year: -1)
        case .forever: nil
        }
        return span.flatMap { calendar.date(byAdding: $0, to: now) }
    }
}
