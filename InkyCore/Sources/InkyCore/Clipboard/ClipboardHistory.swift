import AppKit
import ImageIO
import Observation

/// Watches the pasteboard and keeps what is copied.
///
/// macOS does not say when something is copied. The pasteboard counts its
/// changes, and the count is looked at twice a second: a look costs next to
/// nothing, and what is copied is read only when the count moved.
@MainActor
@Observable
public final class ClipboardHistory {
    /// Whether macOS lets Inky read what other applications copied.
    public enum Access: Sendable {
        case allowed
        /// macOS asks the user at every read. Inky does not read then: a
        /// question with every copy is no way to keep a history.
        case asks
        case denied
    }

    @ObservationIgnored public let store: ClipboardStore
    @ObservationIgnored private let pasteboard: NSPasteboard

    /// Goes up whenever the history changed, for whoever shows it.
    public private(set) var revision = 0
    public private(set) var access = Access.allowed
    public private(set) var isRecording = false

    /// How long a copy stays. Changing it lets go of what is too old now.
    @ObservationIgnored public var retention: ClipboardRetention {
        didSet {
            if retention != oldValue { prune() }
        }
    }

    /// Whether what a password manager marks as confidential is kept.
    /// Turning it off lets go of such copies, unless they are pinned.
    @ObservationIgnored public var keepsConcealed: Bool {
        didSet {
            if !keepsConcealed, oldValue { removeConcealed() }
        }
    }

    @ObservationIgnored private var changeCount: Int
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastPrune = Date.distantPast

    private static let interval: TimeInterval = 0.5
    private static let pruneInterval: TimeInterval = 3600

    public init(
        store: ClipboardStore, pasteboard: NSPasteboard = .general, retention: ClipboardRetention = .threeMonths,
        keepsConcealed: Bool = false
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.retention = retention
        self.keepsConcealed = keepsConcealed
        changeCount = pasteboard.changeCount
    }

    // MARK: - Recording

    /// Begins to keep what is copied from now on. What is on the pasteboard
    /// already was copied before anyone was watching, and is left alone.
    public func start() {
        guard !isRecording else { return }
        isRecording = true
        changeCount = pasteboard.changeCount
        refreshAccess()

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // The system may move a look by this much to do it together with
        // other work, which saves waking up for it alone.
        timer.tolerance = Self.interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        Task { await store.removeStrayImages() }
        prune()
        // Kept by an earlier version, or while they were to be kept.
        if !keepsConcealed { removeConcealed() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRecording = false
    }

    /// Looks at the pasteboard now, and keeps what is on it if it changed.
    public func check() {
        // Also when nothing is copied for a long while.
        if isRecording, Date.now.timeIntervalSince(lastPrune) > Self.pruneInterval { prune() }

        let count = pasteboard.changeCount
        guard count != changeCount else { return }
        changeCount = count
        refreshAccess()
        guard isRecording, access == .allowed else { return }

        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let capture = PasteboardReader.read(
            pasteboard, sourceName: frontmost?.localizedName, sourceBundleID: frontmost?.bundleIdentifier
        ), keepsConcealed || !capture.isConcealed else { return }
        Task {
            guard await store.record(capture) != nil else { return }
            revision += 1
        }
    }

    /// Asks macOS again whether Inky may read the pasteboard.
    public func refreshAccess() {
        guard #available(macOS 15.4, *) else { return }
        let access: Access = switch pasteboard.accessBehavior {
        case .ask: .asks
        case .alwaysDeny: .denied
        // Until the first read, which is when macOS asks, there is nothing
        // to say no to.
        case .default, .alwaysAllow: .allowed
        @unknown default: .allowed
        }
        if access != self.access { self.access = access }
    }

    /// Deletes what has been kept for as long as it is to be.
    public func prune(now: Date = .now) {
        lastPrune = now
        guard let cutoff = retention.cutoff(from: now) else { return }
        Task {
            if await store.prune(before: cutoff) > 0 { revision += 1 }
        }
    }

    private func removeConcealed() {
        Task {
            if await store.removeConcealed() > 0 { revision += 1 }
        }
    }

    // MARK: - Using

    /// Puts an entry back on the pasteboard, as it was copied or, with
    /// `asPlainText`, without its formatting. It is then the latest copy.
    public func copy(_ clip: Clip, asPlainText: Bool = false) async throws {
        guard let payload = await store.payload(of: clip.id) else {
            throw InkyError("That copy is no longer in the history")
        }
        try PasteboardWriter.write(payload, to: pasteboard, asPlainText: asPlainText)
        // Not a new copy: the entry it came from moves up instead.
        changeCount = pasteboard.changeCount
        await store.touch(clip.id)
        revision += 1
    }

    public func setPinned(_ clip: Clip, _ pinned: Bool) async {
        await store.setPinned(clip.id, pinned)
        revision += 1
    }

    public func rename(_ clip: Clip, to name: String?) async {
        await store.rename(clip.id, to: name)
        revision += 1
    }

    public func delete(_ clip: Clip) async {
        await store.delete(clip.id)
        revision += 1
    }

    public func clear(includingPinned: Bool = false) async {
        await store.clear(includingPinned: includingPinned)
        revision += 1
    }
}

// MARK: - Reading

/// Turns what is on a pasteboard into something to keep.
@MainActor
enum PasteboardReader {
    /// Marks set by applications that use the pasteboard to move something
    /// along, not to hold what the user copied. See nspasteboard.org.
    private static let passingTypes: Set<String> = [
        "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType", "Pasteboard generator type",
    ]
    /// Marks set by password managers on what they copy.
    private static let concealedTypes: Set<String> = [
        Pasteboard.concealed.rawValue, "com.agilebits.onepassword",
    ]

    /// As they are preferred: the smaller ones first, TIFF last.
    private static let imageTypes = [
        "public.png", "public.jpeg", "public.heic", "com.compuserve.gif", "org.webmproject.webp", "public.tiff",
    ]
    private static let flavorTypes: [NSPasteboard.PasteboardType] = [.rtf, .html]

    private static let maxTextBytes = 8 << 20
    private static let maxFlavorBytes = 4 << 20
    private static let maxImageBytes = 128 << 20

    static func read(_ pasteboard: NSPasteboard, sourceName: String?, sourceBundleID: String?) -> ClipCapture? {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard !types.isEmpty, types.isDisjoint(with: passingTypes) else { return nil }

        var capture: ClipCapture?
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            capture = .files(urls.map(\.path))
        }
        if capture == nil {
            let text = types.contains(NSPasteboard.PasteboardType.string.rawValue) ? pasteboard.string(forType: .string) : nil
            let imageType = imageTypes.first(where: types.contains)
            // An image copied in a browser comes with its address. Text that
            // comes with a picture of itself, as from a spreadsheet, is text.
            let isImage = imageType != nil && (text.map { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty || ClipClassifier.isLink(trimmed)
            } ?? true)

            if isImage, let imageType,
               let data = pasteboard.data(forType: NSPasteboard.PasteboardType(imageType)),
               !data.isEmpty, data.count <= maxImageBytes {
                capture = .image(data, type: imageType, from: sourceName)
            } else if let text, text.utf8.count <= maxTextBytes {
                capture = .text(text)
                if let kind = capture?.kind, kind == .text || kind == .code {
                    for type in flavorTypes where types.contains(type.rawValue) {
                        if let data = pasteboard.data(forType: type), !data.isEmpty, data.count <= maxFlavorBytes {
                            capture?.flavors[type.rawValue] = data
                        }
                    }
                }
            }
        }
        guard var capture else { return nil }

        // Inky is never the frontmost application while its launcher is up.
        let isOwn = types.contains(Pasteboard.copiedByInky.rawValue)
        capture.sourceName = isOwn ? "Inky" : sourceName
        capture.sourceBundleID = isOwn ? Bundle.main.bundleIdentifier : sourceBundleID
        capture.isConcealed = !types.isDisjoint(with: concealedTypes)
        return capture
    }
}

// MARK: - Writing

/// Puts an entry of the history back on a pasteboard.
@MainActor
enum PasteboardWriter {
    static func write(_ payload: ClipPayload, to pasteboard: NSPasteboard, asPlainText: Bool) throws {
        switch payload.kind {
        case .file:
            let paths = (payload.text ?? "").split(separator: "\n").map(String.init)
            let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard !existing.isEmpty else {
                throw InkyError(paths.count == 1 ? "The file is no longer there" : "The files are no longer there")
            }
            pasteboard.clearContents()
            if asPlainText {
                pasteboard.setString(existing.joined(separator: "\n"), forType: .string)
            } else {
                pasteboard.writeObjects(existing.map { URL(fileURLWithPath: $0) as NSURL })
            }
            // On the first item, which is where it is looked for.
            if payload.isConcealed { pasteboard.setString("", forType: Pasteboard.concealed) }
        case .image:
            guard let url = payload.imageURL, let data = try? Data(contentsOf: url) else {
                throw InkyError("The image is no longer there")
            }
            let type = payload.imageType ?? "public.png"
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
            // Some applications take only one kind of image. The others are
            // made when one of them asks.
            let others = [NSPasteboard.PasteboardType.png, .tiff].filter { $0.rawValue != type }
            item.setDataProvider(ImageConverter(url: url), forTypes: others)
            if payload.isConcealed { item.setString("", forType: Pasteboard.concealed) }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
        case .text, .code, .path, .link, .color:
            guard let text = payload.text else { throw InkyError("That copy is no longer in the history") }
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if !asPlainText {
                for (type, data) in payload.flavors {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
            }
            if payload.isConcealed { item.setString("", forType: Pasteboard.concealed) }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
        }
    }
}

/// Hands out an image of the history as another kind of image.
private final class ImageConverter: NSObject, NSPasteboardItemDataProvider {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let data = NSMutableData()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let destination = CGImageDestinationCreateWithData(data, type.rawValue as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        if CGImageDestinationFinalize(destination) {
            item.setData(data as Data, forType: type)
        }
    }
}
