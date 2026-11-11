import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// The clipboard history on disk: a SQLite database of what was copied, and
/// next to it a folder of the images.
///
/// Everything here runs off the main thread. A row is small: what lists an
/// entry sits in front, and the copied text comes last, where listing never
/// reads it. Searching goes through an index of every run of three
/// characters, so that words are found anywhere in a text without reading
/// the texts. Images are files, each with a small copy to show.
public actor ClipboardStore {
    /// The folder of images. A `Clip` of an image names its file in here.
    public nonisolated let imageDirectory: URL

    private let directory: URL
    private let database: SQLiteDatabase
    /// Whether the search index is there. Without it, a search reads the texts.
    private let hasIndex: Bool

    private static let log = Logger(subsystem: "io.github.hinkolas.inky", category: "clipboard")
    /// How much of a text is indexed. What is searched for is at the
    /// beginning of a long text or it is not what the text is known by.
    private static let indexedCharacters = 100_000
    /// How much of a text is read to show it.
    private static let shownCharacters = 4000
    /// The longest side of the copy an image is shown by, in pixels.
    private static let previewSize = 640
    /// Image types that are kept as they are. Anything else is kept as PNG:
    /// TIFF, which most images are copied as, is many times the size.
    private static let keptImageTypes: Set<String> = [
        "public.png", "public.jpeg", "com.compuserve.gif", "public.heic", "org.webmproject.webp",
    ]

    /// Opens the history in `directory`, or begins one there.
    public init(directory: URL) {
        self.directory = directory
        imageDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: imageDirectory,
            withIntermediateDirectories: true,
            // What was copied is nobody else's to read.
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let file = directory.appendingPathComponent("history.sqlite")
        var opened = try? Self.open(file.path)
        if opened == nil, FileManager.default.fileExists(atPath: file.path) {
            // A file that cannot be read is put aside rather than lost, and
            // the history begins again.
            Self.log.error("The clipboard history could not be opened and was put aside")
            let aside = directory.appendingPathComponent("history.unreadable.sqlite")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: file.path + suffix)
            }
            opened = try? Self.open(file.path)
        }
        // Without a file there is still a history, until Inky quits.
        let database = opened ?? (try? Self.open(":memory:"))
        guard let database else { fatalError("SQLite could not open a database in memory") }
        self.database = database
        hasIndex = ((try? database.query(
            "SELECT 1 FROM sqlite_master WHERE name = 'clips_search'", []
        ) { _ in true }) ?? []).isEmpty == false
    }

    /// Whether searching goes through the index.
    var isIndexed: Bool { hasIndex }

    private static func open(_ path: String) throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: path)
        let version = try database.query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        if version == 0 {
            // Has to be said before the first table is there.
            try database.execute("PRAGMA auto_vacuum = INCREMENTAL")
        }
        try database.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA secure_delete = ON;
            """)
        guard version == 0 else { return database }

        try database.transaction {
            try database.execute(schema)
            try database.execute("PRAGMA user_version = 1")
        }
        // The index needs a SQLite that has it. One that does not still
        // keeps the history, and searches it the slow way.
        do {
            try database.transaction { try database.execute(searchSchema) }
        } catch {
            log.error("No search index for the clipboard history: \(String(describing: error), privacy: .public)")
        }
        return database
    }

    /// `text` is the last column: SQLite reads a row up to the column it is
    /// asked for, so a long text is only read when it is wanted.
    private static let schema = """
        CREATE TABLE clips (
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,
            hash BLOB NOT NULL UNIQUE,
            title TEXT NOT NULL,
            name TEXT,
            source_name TEXT,
            source_bundle TEXT,
            first_copied REAL NOT NULL,
            last_copied REAL NOT NULL,
            copies INTEGER NOT NULL DEFAULT 1,
            pinned REAL,
            bytes INTEGER NOT NULL DEFAULT 0,
            width INTEGER,
            height INTEGER,
            location TEXT,
            items INTEGER NOT NULL DEFAULT 1,
            rich INTEGER NOT NULL DEFAULT 0,
            concealed INTEGER NOT NULL DEFAULT 0,
            image_type TEXT,
            text TEXT
        );
        CREATE INDEX clips_recent ON clips(last_copied DESC, id DESC);
        CREATE INDEX clips_kind ON clips(kind, last_copied DESC);
        CREATE INDEX clips_pinned ON clips(pinned) WHERE pinned IS NOT NULL;
        CREATE TABLE flavors (
            clip INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
            type TEXT NOT NULL,
            data BLOB NOT NULL,
            PRIMARY KEY (clip, type)
        ) WITHOUT ROWID;
        """

    /// The index holds no texts of its own, only where their trigrams are.
    private static let searchSchema = """
        CREATE VIRTUAL TABLE clips_search USING fts5(
            text, name, content = '', contentless_delete = 1, tokenize = 'trigram'
        );
        CREATE TRIGGER clips_inserted AFTER INSERT ON clips BEGIN
            INSERT INTO clips_search(rowid, text, name)
            VALUES (new.id, substr(coalesce(new.text, new.title), 1, \(indexedCharacters)), new.name);
        END;
        CREATE TRIGGER clips_deleted AFTER DELETE ON clips BEGIN
            DELETE FROM clips_search WHERE rowid = old.id;
        END;
        CREATE TRIGGER clips_renamed AFTER UPDATE OF name ON clips BEGIN
            DELETE FROM clips_search WHERE rowid = old.id;
            INSERT INTO clips_search(rowid, text, name)
            VALUES (new.id, substr(coalesce(new.text, new.title), 1, \(indexedCharacters)), new.name);
        END;
        """

    // MARK: - Recording

    /// Adds what was copied, or moves the entry it already is to the top.
    /// Returns the entry's id, or nil if it could not be kept.
    @discardableResult
    public func record(_ capture: ClipCapture) -> Int64? {
        do {
            return try database.transaction { try insert(capture) }
        } catch {
            Self.log.error("A copy could not be kept: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func insert(_ capture: ClipCapture) throws -> Int64 {
        let hash = capture.hash
        let existing = try database.query("SELECT id FROM clips WHERE hash = ?", [.blob(hash)]) { Int64($0.int(0)) }.first
        let id: Int64
        if let existing {
            id = existing
            try database.run("""
                UPDATE clips SET last_copied = max(last_copied, ?), copies = copies + 1,
                    source_name = ?, source_bundle = ?, concealed = ?
                WHERE id = ?
                """, [
                    .date(capture.date), .optional(capture.sourceName), .optional(capture.sourceBundleID),
                    .integer(capture.isConcealed ? 1 : 0), .integer(existing),
                ])
            // The formatting of the latest copy is the one that is pasted.
            if capture.image == nil {
                try database.run("DELETE FROM flavors WHERE clip = ?", [.integer(existing)])
                try database.run(
                    "UPDATE clips SET rich = ?, bytes = ? WHERE id = ?",
                    [.integer(capture.flavors.isEmpty ? 0 : 1), .integer(capture.byteCount), .integer(existing)]
                )
            }
        } else {
            var stored: StoredImage?
            if let image = capture.image {
                stored = try store(image, type: capture.imageType ?? "public.png", hash: hash)
            }
            try database.run("""
                INSERT INTO clips (
                    kind, hash, title, source_name, source_bundle, first_copied, last_copied,
                    bytes, width, height, location, items, rich, concealed, image_type, text
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .text(capture.kind.rawValue), .blob(hash), .text(capture.title),
                    .optional(capture.sourceName), .optional(capture.sourceBundleID),
                    .date(capture.date), .date(capture.date),
                    .integer(stored?.bytes ?? capture.byteCount),
                    stored.map { .integer($0.width) } ?? .null, stored.map { .integer($0.height) } ?? .null,
                    .optional(stored?.name ?? capture.location), .integer(capture.items),
                    .integer(capture.flavors.isEmpty ? 0 : 1), .integer(capture.isConcealed ? 1 : 0),
                    .optional(stored?.type), .optional(capture.text),
                ])
            id = database.lastInsertedID
        }
        for (type, data) in capture.flavors where !data.isEmpty {
            try database.run(
                "INSERT INTO flavors (clip, type, data) VALUES (?, ?, ?)",
                [.integer(id), .text(type), .blob(data)]
            )
        }
        return id
    }

    private struct StoredImage {
        var name: String
        var type: String
        var width: Int
        var height: Int
        var bytes: Int
    }

    /// Writes an image into the folder, and a small copy of it to show.
    private func store(_ data: Data, type: String, hash: Data) throws -> StoredImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw InkyError("What was copied is not an image")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        let stem = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        let keeps = Self.keptImageTypes.contains(type)
        let storedType = keeps ? type : "public.png"
        let name = stem + "." + (UTType(storedType)?.preferredFilenameExtension ?? "png")
        let url = imageDirectory.appendingPathComponent(name)

        if keeps {
            try data.write(to: url, options: .atomic)
        } else {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, storedType as CFString, 1, nil) else {
                throw InkyError("The image could not be written")
            }
            // Takes what the image says about itself along, such as how
            // many pixels of it are a point.
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            guard CGImageDestinationFinalize(destination) else { throw InkyError("The image could not be written") }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.previewSize,
        ]
        if let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
           let destination = CGImageDestinationCreateWithURL(
               Self.previewURL(for: name, in: imageDirectory) as CFURL, "public.png" as CFString, 1, nil
           ) {
            CGImageDestinationAddImage(destination, preview, nil)
            CGImageDestinationFinalize(destination)
        }

        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count
        return StoredImage(name: name, type: storedType, width: width, height: height, bytes: bytes)
    }

    private static func previewURL(for name: String, in directory: URL) -> URL {
        directory.appendingPathComponent((name as NSString).deletingPathExtension + ".preview.png")
    }

    /// Where the small copy of an image is, to show it.
    public nonisolated func previewURL(of clip: Clip) -> URL? {
        guard clip.kind == .image, let name = clip.location else { return nil }
        return Self.previewURL(for: name, in: imageDirectory)
    }

    // MARK: - Reading

    private static let columns = """
        c.id, c.kind, c.title, c.name, c.source_name, c.source_bundle, c.first_copied, c.last_copied,
        c.copies, c.pinned, c.bytes, c.width, c.height, c.location, c.items, c.rich, c.concealed
        """

    private static func clip(_ row: SQLiteRow) -> Clip {
        Clip(
            id: Int64(row.int(0)),
            kind: row.text(1).flatMap(ClipKind.init) ?? .text,
            title: row.text(2) ?? "",
            name: row.text(3),
            sourceName: row.text(4),
            sourceBundleID: row.text(5),
            firstCopied: row.date(6),
            lastCopied: row.date(7),
            copies: row.int(8),
            pinned: row.optionalDate(9),
            byteCount: row.int(10),
            width: row.optionalInt(11),
            height: row.optionalInt(12),
            location: row.text(13),
            items: row.int(14),
            hasFormatting: row.bool(15),
            isConcealed: row.bool(16)
        )
    }

    /// What a screen shows at first: the pins, the newest `limit` entries
    /// the query finds, and how many there are of each kind.
    public func snapshot(_ query: ClipQuery, limit: Int) -> ClipSnapshot {
        var snapshot = ClipSnapshot()
        do {
            snapshot.pins = try database.query(
                "SELECT \(Self.columns) FROM clips c WHERE c.pinned IS NOT NULL ORDER BY c.pinned, c.id", [], Self.clip
            )
            if query.text.allSatisfy(\.isWhitespace), query.filter == .all {
                snapshot.pinned = snapshot.pins
            } else if !snapshot.pins.isEmpty {
                // Pinned entries are listed whenever they were copied.
                var pinned = query
                pinned.since = nil
                let (conditions, values) = conditions(for: pinned)
                snapshot.pinned = try database.query("""
                    SELECT \(Self.columns) FROM clips c
                    WHERE c.pinned IS NOT NULL\(conditions) ORDER BY c.pinned, c.id
                    """, values, Self.clip)
            }
            let page = try entries(query, after: nil, limit: limit)
            snapshot.clips = page.clips
            snapshot.hasMore = page.hasMore

            let counts = try database.query(
                "SELECT kind, COUNT(*) FROM clips" + (query.since == nil ? "" : " WHERE last_copied >= ?") + " GROUP BY kind",
                query.since.map { [.date($0)] } ?? []
            ) { (kind: $0.text(0).flatMap(ClipKind.init), count: $0.int(1)) }
            for entry in counts {
                if let kind = entry.kind { snapshot.counts[kind] = entry.count }
            }
        } catch {
            Self.log.error("The clipboard history could not be read: \(String(describing: error), privacy: .public)")
        }
        return snapshot
    }

    /// The entries that follow `last` in what the query finds.
    public func page(_ query: ClipQuery, after last: Clip, limit: Int) -> (clips: [Clip], hasMore: Bool) {
        (try? entries(query, after: last, limit: limit)) ?? ([], false)
    }

    /// Entries that are not pinned, newest first.
    private func entries(_ query: ClipQuery, after last: Clip?, limit: Int) throws -> (clips: [Clip], hasMore: Bool) {
        var (conditions, values) = conditions(for: query)
        if let last {
            conditions += " AND (c.last_copied < ? OR (c.last_copied = ? AND c.id < ?))"
            values += [.date(last.lastCopied), .date(last.lastCopied), .integer(last.id)]
        }
        // One more than asked for says whether there are more.
        values.append(.integer(limit + 1))
        var clips = try database.query("""
            SELECT \(Self.columns) FROM clips c
            WHERE c.pinned IS NULL\(conditions)
            ORDER BY c.last_copied DESC, c.id DESC LIMIT ?
            """, values, Self.clip)
        let hasMore = clips.count > limit
        if hasMore { clips.removeLast() }
        return (clips, hasMore)
    }

    /// What narrows a query down, to follow a first condition.
    private func conditions(for query: ClipQuery) -> (sql: String, values: [SQLiteValue]) {
        var sql = ""
        var values: [SQLiteValue] = []

        let terms = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
        // The index knows runs of three characters. Anything shorter is
        // looked for in the texts themselves, which is quick where it
        // matters: nearly everything has an "a" in it, and the newest come first.
        let indexed = hasIndex ? terms.filter { $0.count >= 3 } : []
        if !indexed.isEmpty {
            sql += " AND c.id IN (SELECT rowid FROM clips_search WHERE clips_search MATCH ?)"
            values.append(.text(indexed.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")))
        }
        for term in terms where !indexed.contains(term) {
            sql += " AND (coalesce(c.text, c.title) LIKE ? ESCAPE '\\' OR c.name LIKE ? ESCAPE '\\')"
            let pattern = "%" + term.replacing(/[\\%_]/) { "\\" + $0.output } + "%"
            values += [.text(pattern), .text(pattern)]
        }
        if let kinds = query.filter.kinds {
            sql += " AND c.kind IN (" + kinds.map { "'\($0.rawValue)'" }.joined(separator: ", ") + ")"
        }
        if let since = query.since {
            sql += " AND c.last_copied >= ?"
            values.append(.date(since))
        }
        return (sql, values)
    }

    /// One entry as it is now, or nil if it is gone.
    public func clip(_ id: Int64) -> Clip? {
        (try? database.query("SELECT \(Self.columns) FROM clips c WHERE c.id = ?", [.integer(id)], Self.clip))?.first
    }

    /// What an entry holds, to show it.
    public func content(of id: Int64) -> ClipContent? {
        let rows = try? database.query("""
            SELECT substr(text, 1, \(Self.shownCharacters)), length(text),
                length(text) - length(replace(text, char(10), '')) + 1
            FROM clips WHERE id = ?
            """, [.integer(id)]) { row in
                ClipContent(
                    id: id,
                    text: row.text(0),
                    isTruncated: row.int(1) > Self.shownCharacters,
                    characters: row.int(1),
                    lines: row.isNull(2) ? 0 : row.int(2)
                )
            }
        return rows?.first
    }

    /// What an entry holds, to put it back on the pasteboard.
    public func payload(of id: Int64) -> ClipPayload? {
        do {
            let rows = try database.query(
                "SELECT kind, location, image_type, text FROM clips WHERE id = ?", [.integer(id)]
            ) { row in
                (kind: row.text(0).flatMap(ClipKind.init) ?? .text, location: row.text(1), imageType: row.text(2), text: row.text(3))
            }
            guard let row = rows.first else { return nil }
            let flavors = try database.query("SELECT type, data FROM flavors WHERE clip = ?", [.integer(id)]) {
                (type: $0.text(0) ?? "", data: $0.data(1) ?? Data())
            }
            return ClipPayload(
                kind: row.kind,
                text: row.text,
                flavors: Dictionary(flavors.map { ($0.type, $0.data) }, uniquingKeysWith: { first, _ in first }),
                imageURL: row.kind == .image ? row.location.map(imageDirectory.appendingPathComponent) : nil,
                imageType: row.imageType
            )
        } catch {
            return nil
        }
    }

    public func statistics() -> ClipboardStatistics {
        var statistics = ClipboardStatistics()
        let counts = try? database.query("SELECT COUNT(*), COUNT(pinned) FROM clips") { ($0.int(0), $0.int(1)) }
        if let (entries, pinned) = counts?.first {
            statistics.entries = entries
            statistics.pinned = pinned
        }
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        while let file = files?.nextObject() as? URL {
            statistics.bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return statistics
    }

    // MARK: - Changing

    /// Makes the entry the one that was copied last, as when it is pasted.
    public func touch(_ id: Int64, at date: Date = .now) {
        _ = try? database.run(
            "UPDATE clips SET last_copied = ?, copies = copies + 1 WHERE id = ?", [.date(date), .integer(id)]
        )
    }

    /// Pins the entry, which keeps it for good, or lets it go again. An
    /// entry that is let go loses its name.
    public func setPinned(_ id: Int64, _ pinned: Bool, at date: Date = .now) {
        if pinned {
            _ = try? database.run(
                "UPDATE clips SET pinned = ? WHERE id = ? AND pinned IS NULL", [.date(date), .integer(id)]
            )
        } else {
            _ = try? database.run("UPDATE clips SET pinned = NULL, name = NULL WHERE id = ?", [.integer(id)])
        }
    }

    /// Calls a pinned entry `name`. Nothing, or nil, takes its name away.
    public func rename(_ id: Int64, to name: String?) {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? database.run(
            "UPDATE clips SET name = ? WHERE id = ?", [.optional(name?.isEmpty == false ? name : nil), .integer(id)]
        )
    }

    public func delete(_ id: Int64) {
        remove(where: "id = ?", [.integer(id)])
    }

    /// Deletes the history. What is pinned stays unless `includingPinned`.
    public func clear(includingPinned: Bool = false) {
        remove(where: includingPinned ? "1" : "pinned IS NULL", [])
    }

    /// Deletes what was last copied before `date` and is not pinned.
    /// Returns how many entries went.
    @discardableResult
    public func prune(before date: Date) -> Int {
        remove(where: "pinned IS NULL AND last_copied < ?", [.date(date)])
    }

    @discardableResult
    private func remove(where condition: String, _ values: [SQLiteValue]) -> Int {
        do {
            let (images, removed) = try database.transaction {
                let images = try database.query(
                    "SELECT location FROM clips WHERE kind = 'image' AND location IS NOT NULL AND \(condition)", values
                ) { $0.text(0) ?? "" }
                return (images, try database.run("DELETE FROM clips WHERE \(condition)", values))
            }
            for name in images {
                try? FileManager.default.removeItem(at: imageDirectory.appendingPathComponent(name))
                try? FileManager.default.removeItem(at: Self.previewURL(for: name, in: imageDirectory))
            }
            // Gives the room back to the disk.
            if removed > 0 { try? database.execute("PRAGMA incremental_vacuum") }
            return removed
        } catch {
            Self.log.error("The clipboard history could not be changed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    /// Removes images no entry names, as are left when Inky quits between
    /// writing one and recording it.
    public func removeStrayImages() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: imageDirectory.path), !names.isEmpty,
              let kept = try? database.query("SELECT location FROM clips WHERE kind = 'image'", [], { $0.text(0) ?? "" })
        else { return }
        var known = Set(kept)
        for name in kept {
            known.insert(Self.previewURL(for: name, in: imageDirectory).lastPathComponent)
        }
        for name in names where !known.contains(name) {
            try? FileManager.default.removeItem(at: imageDirectory.appendingPathComponent(name))
        }
    }
}
