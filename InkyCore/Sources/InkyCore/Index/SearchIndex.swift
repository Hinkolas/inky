import Foundation
import Observation
import OSLog

/// The items the search finds that are not commands, by the source they
/// come from.
///
/// Everything is held in memory, ready to be matched in the frame a key is
/// pressed in. A source that asks for it has its items kept on disk as
/// well: they are read back when Inky starts, and found before the source
/// has done anything.
///
/// A source changes its items in batches, see `SourceIndex`. A batch is all
/// or nothing, in memory and on disk, and carries the source's own note of
/// how far it has come along with it.
@MainActor
@Observable
public final class SearchIndex {
    /// Where a source's items are kept.
    public enum Storage: Sendable {
        /// Until Inky quits. The source indexes them again every time.
        case memory
        /// From one launch to the next, in Inky's own database.
        case disk
    }

    /// What the index has to know of a source to open it.
    public struct Registration: Sendable {
        public var id: String
        public var storage: Storage
        public var version: Int

        public init(id: String, storage: Storage, version: Int = 1) {
            self.id = id
            self.storage = storage
            self.version = version
        }
    }

    /// The changes a source makes in one go. They are applied in the order
    /// they are asked for.
    public struct Batch {
        fileprivate enum Change {
            case index([SearchableItem])
            case deleteIDs([String])
            case deleteDomains([String])
            case deleteAll
        }

        fileprivate var changes: [Change] = []

        /// The source's note of how far its items have come, such as the
        /// token of the last change it has seen. It is kept with the items,
        /// so the two never say different things.
        public var state: Data?

        /// Adds the items, or replaces the ones that are there under their ids.
        public mutating func index(_ items: [SearchableItem]) {
            changes.append(.index(items))
        }

        public mutating func delete(ids: [String]) {
            changes.append(.deleteIDs(ids))
        }

        /// Deletes the items of these groups, and of the groups within them.
        public mutating func delete(domains: [String]) {
            changes.append(.deleteDomains(domains))
        }

        public mutating func deleteAll() {
            changes.append(.deleteAll)
        }
    }

    /// An item with what it is matched by, worked out once.
    struct Entry {
        let item: SearchableItem
        let title: FuzzyMatcher.Target
        let keywords: [FuzzyMatcher.Target]

        init(_ item: SearchableItem) {
            self.item = item
            title = FuzzyMatcher.Target(item.title)
            keywords = item.keywords.map(FuzzyMatcher.Target.init)
        }
    }

    private struct Source {
        var storage: Storage
        var version: Int
        var entries: [String: Entry] = [:]
        var state: Data?
        /// Whether changes are taken. Not while its module is switched off.
        var isOpen = true
    }

    /// Observed, so that settings count the items as they come.
    private var sources: [String: Source] = [:]

    /// Called after items changed and visible results may be stale.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let store: SearchIndexStore?
    /// What is to be written, in the order it was asked for.
    @ObservationIgnored private let writes: AsyncStream<@Sendable () async -> Void>.Continuation

    /// Whether items can be kept on disk. Without a file, or with one that
    /// cannot be opened, every source is kept in memory.
    public var isPersistent: Bool { store != nil }

    /// - Parameter fileURL: The database the items are kept in. Nil keeps
    ///   them in memory only.
    public init(fileURL: URL?) {
        store = fileURL.flatMap(SearchIndexStore.init(fileURL:))
        let (stream, writes) = AsyncStream<@Sendable () async -> Void>.makeStream()
        self.writes = writes
        Task.detached(priority: .utility) {
            for await write in stream { await write() }
        }
    }

    deinit {
        writes.finish()
    }

    // MARK: - Sources

    /// Makes the sources known and reads what was kept of their items.
    /// Returns the ids of the sources the index has nothing of that it can
    /// trust, which are to index everything anew. What is kept of sources
    /// that are not named is deleted.
    public func open(_ registrations: [Registration]) async -> Set<String> {
        var stale: Set<String> = []
        for registration in registrations {
            var source = Source(storage: registration.storage, version: registration.version)
            if registration.storage == .disk, let store,
               let kept = await store.load(registration.id, version: registration.version) {
                let now = Date.now
                for item in kept.items where !item.isExpired(at: now) {
                    source.entries[item.id] = Entry(item)
                }
                source.state = kept.state
                // What has expired is not kept any longer either.
                let expired = kept.items.filter { $0.isExpired(at: now) }.map(\.id)
                if !expired.isEmpty {
                    let change = SearchIndexStore.Change(
                        source: registration.id, clears: false, deleted: expired, written: [], state: kept.state
                    )
                    write { await store.apply(change) }
                }
            } else {
                stale.insert(registration.id)
            }
            sources[registration.id] = source
        }
        if let store {
            let kept = Set(registrations.filter { $0.storage == .disk }.map(\.id))
            write { await store.prune(keeping: kept) }
        }
        return stale
    }

    /// Says that the source has indexed everything it has. Until then what
    /// is kept of it on disk does not count, and is not read back.
    public func markComplete(_ id: String) {
        guard let source = sources[id], source.storage == .disk, let store else { return }
        write { await store.markComplete(id, version: source.version) }
    }

    /// Deletes every item of a source and stops taking changes from it, as
    /// when its module is switched off.
    public func close(_ id: String) {
        guard var source = sources[id] else { return }
        let hadItems = !source.entries.isEmpty
        source.entries = [:]
        source.state = nil
        source.isOpen = false
        sources[id] = source
        if let store { write { await store.remove(id) } }
        if hadItems { onChange?() }
    }

    /// Takes changes from the source again.
    public func reopen(_ id: String) {
        sources[id]?.isOpen = true
    }

    // MARK: - Reading

    public func count(of source: String) -> Int {
        sources[source]?.entries.count ?? 0
    }

    public func state(of source: String) -> Data? {
        sources[source]?.state
    }

    public func item(_ id: String, of source: String) -> SearchableItem? {
        sources[source]?.entries[id]?.item
    }

    /// Every item of a source, in no order.
    public func items(of source: String) -> [SearchableItem] {
        sources[source]?.entries.values.map(\.item) ?? []
    }

    func entries(of source: String) -> Dictionary<String, Entry>.Values? {
        sources[source]?.entries.values
    }

    // MARK: - Writing

    /// Applies a batch of changes to a source's items.
    ///
    /// - Parameter expected: If given, the batch is applied only while the
    ///   state kept with the items is this one. A source that syncs by what
    ///   changed since a token learns this way that the index is not where
    ///   it thinks it is, and indexes everything anew instead.
    /// - Returns: False if nothing was applied: the state was another one,
    ///   or the source is unknown or closed.
    @discardableResult
    func update(_ id: String, expecting expected: Data?? = nil, _ changes: (inout Batch) -> Void) -> Bool {
        guard var source = sources[id], source.isOpen else { return false }
        if let expected, expected != source.state { return false }

        var batch = Batch(state: source.state)
        changes(&batch)

        // What the batch comes to, for the copy on disk.
        var clears = false
        var written: [String: SearchableItem] = [:]
        var deleted: Set<String> = []
        func delete(_ ids: some Sequence<String>) {
            for id in ids {
                source.entries[id] = nil
                written[id] = nil
                deleted.insert(id)
            }
        }
        for change in batch.changes {
            switch change {
            case .index(let items):
                for item in items {
                    source.entries[item.id] = Entry(item)
                    written[item.id] = item
                    deleted.remove(item.id)
                }
            case .deleteIDs(let ids):
                delete(ids)
            case .deleteDomains(let domains):
                delete(source.entries.values.map(\.item).filter { item in domains.contains(where: item.isIn) }.map(\.id))
            case .deleteAll:
                source.entries = [:]
                written = [:]
                deleted = []
                clears = true
            }
        }
        source.state = batch.state
        sources[id] = source

        if source.storage == .disk, let store {
            let change = SearchIndexStore.Change(
                source: id, clears: clears, deleted: Array(deleted), written: Array(written.values), state: batch.state
            )
            write { await store.apply(change) }
        }
        onChange?()
        return true
    }

    private func write(_ operation: @escaping @Sendable () async -> Void) {
        writes.yield(operation)
    }

    /// Returns once everything asked for so far is on disk.
    public func flush() async {
        await withCheckedContinuation { continuation in
            write { continuation.resume() }
        }
    }
}

/// A source's own part of the index: the only thing it needs to know of it.
@MainActor
public struct SourceIndex {
    let index: SearchIndex
    public let source: String

    init(_ index: SearchIndex, source: String) {
        self.index = index
        self.source = source
    }

    public var count: Int { index.count(of: source) }

    /// What the source last kept with its items, see `SearchIndex.Batch.state`.
    public var state: Data? { index.state(of: source) }

    public func item(_ id: String) -> SearchableItem? { index.item(id, of: source) }

    /// Applies changes in one go: all of them, or, when the index does not
    /// take changes from the source, none.
    @discardableResult
    public func update(_ changes: (inout SearchIndex.Batch) -> Void) -> Bool {
        index.update(source, changes)
    }

    /// Applies changes only while the kept state is `expected`. Returns
    /// false, with nothing changed, if it is not.
    @discardableResult
    public func update(expecting expected: Data?, _ changes: (inout SearchIndex.Batch) -> Void) -> Bool {
        index.update(source, expecting: .some(expected), changes)
    }

    /// Adds the items, or replaces the ones that are there under their ids.
    public func index(_ items: [SearchableItem]) {
        update { $0.index(items) }
    }

    public func delete(ids: [String]) {
        update { $0.delete(ids: ids) }
    }

    /// Deletes the items of these groups, and of the groups within them.
    public func delete(domains: [String]) {
        update { $0.delete(domains: domains) }
    }

    public func deleteAll() {
        update { $0.deleteAll() }
    }

    /// Makes `items` all there is of the source.
    public func replaceAll(with items: [SearchableItem], state: Data? = nil) {
        update { batch in
            batch.deleteAll()
            batch.index(items)
            batch.state = state
        }
    }
}

/// The index on disk: one SQLite database, used off the main thread.
actor SearchIndexStore {
    /// What a batch comes to.
    struct Change: Sendable {
        var source: String
        /// Whether everything that was there goes first.
        var clears: Bool
        var deleted: [String]
        var written: [SearchableItem]
        var state: Data?
    }

    private let database: SQLiteDatabase
    private static let log = Logger(subsystem: "io.github.hinkolas.inky", category: "index")

    /// Nil if the database cannot be opened. Nothing is kept then.
    init?(fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            // What is found is nobody else's to read.
            attributes: [.posixPermissions: 0o700]
        )
        do {
            database = try Self.open(fileURL.path)
        } catch {
            Self.log.error("The search index could not be opened; items are kept in memory only: \(String(describing: error), privacy: .public)")
            return nil
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func open(_ path: String) throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: path)
        let version = try database.query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        guard version <= 1 else { throw InkyError("This search index needs a newer version of Inky") }
        try database.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA secure_delete = ON;
            """)
        guard version == 0 else { return database }
        try database.transaction {
            try database.execute("""
                CREATE TABLE sources (
                    id TEXT PRIMARY KEY,
                    version INTEGER NOT NULL,
                    complete INTEGER NOT NULL DEFAULT 0,
                    state BLOB
                ) WITHOUT ROWID;
                CREATE TABLE items (
                    source TEXT NOT NULL,
                    id TEXT NOT NULL,
                    item BLOB NOT NULL,
                    PRIMARY KEY (source, id)
                ) WITHOUT ROWID;
                PRAGMA user_version = 1;
                """)
        }
        return database
    }

    /// The items kept of a source, if they are complete, were made under
    /// this version, and can all be read. Otherwise they are deleted.
    func load(_ source: String, version: Int) -> (items: [SearchableItem], state: Data?)? {
        do {
            let rows = try database.query(
                "SELECT state FROM sources WHERE id = ? AND version = ? AND complete = 1", [.text(source), .integer(version)]
            ) { $0.data(0) }
            guard let state = rows.first else {
                try delete(source)
                return nil
            }
            let decoder = JSONDecoder()
            let items = try database.query("SELECT item FROM items WHERE source = ?", [.text(source)]) { $0.data(0) }
                .map { try decoder.decode(SearchableItem.self, from: $0 ?? Data()) }
            return (items, state)
        } catch {
            Self.log.error("What was kept of \(source, privacy: .public) could not be read: \(String(describing: error), privacy: .public)")
            try? delete(source)
            return nil
        }
    }

    func apply(_ change: Change) {
        do {
            let encoder = JSONEncoder()
            try database.transaction {
                // The source is there from its first change on, not complete yet.
                try database.run(
                    "INSERT INTO sources (id, version, state) VALUES (?, 0, ?) ON CONFLICT (id) DO UPDATE SET state = excluded.state",
                    [.text(change.source), change.state.map(SQLiteValue.blob) ?? .null]
                )
                if change.clears {
                    try database.run("DELETE FROM items WHERE source = ?", [.text(change.source)])
                }
                for id in change.deleted {
                    try database.run("DELETE FROM items WHERE source = ? AND id = ?", [.text(change.source), .text(id)])
                }
                for item in change.written {
                    try database.run(
                        "INSERT OR REPLACE INTO items (source, id, item) VALUES (?, ?, ?)",
                        [.text(change.source), .text(item.id), .blob(try encoder.encode(item))]
                    )
                }
            }
        } catch {
            // What is on disk is behind what is in memory now. It must not
            // be taken for the whole of it the next time.
            Self.log.error("A change to the items of \(change.source, privacy: .public) was not kept: \(String(describing: error), privacy: .public)")
            _ = try? database.run("UPDATE sources SET complete = 0 WHERE id = ?", [.text(change.source)])
        }
    }

    func markComplete(_ source: String, version: Int) {
        _ = try? database.run(
            "INSERT INTO sources (id, version, complete) VALUES (?, ?, 1) ON CONFLICT (id) DO UPDATE SET version = excluded.version, complete = 1",
            [.text(source), .integer(version)]
        )
    }

    func remove(_ source: String) {
        try? delete(source)
    }

    /// Deletes what is kept of every source but these.
    func prune(keeping sources: Set<String>) {
        let kept = (try? database.query("SELECT id FROM sources") { $0.text(0) ?? "" }) ?? []
        for source in kept where !sources.contains(source) {
            try? delete(source)
        }
    }

    private func delete(_ source: String) throws {
        try database.transaction {
            try database.run("DELETE FROM items WHERE source = ?", [.text(source)])
            try database.run("DELETE FROM sources WHERE id = ?", [.text(source)])
        }
    }
}
