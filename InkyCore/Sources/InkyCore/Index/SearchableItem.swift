import Foundation

/// Something a module wants found in the search that is not a command: a
/// contact, a repository, a note.
///
/// An item is only data. It can be kept on disk and handed from one process
/// to another, which a `ResultItem`, with the code of its actions, cannot.
/// What can be done with an item its source says when it is asked, see
/// `SearchableSource.actions(for:)`.
///
/// The design follows Core Spotlight's `CSSearchableItem`: an identifier of
/// the item, one of the group it belongs to, what it is found and shown by,
/// and when it stops being true.
public struct SearchableItem: Identifiable, Codable, Hashable, Sendable {
    /// Tells the item from the others of its source, and stays the same from
    /// one launch to the next. Indexing an item again under its id replaces
    /// it, and what the user picks is remembered by it.
    public var id: String
    /// The group of its source's items it belongs to, to delete them
    /// together. Dots make groups within groups: deleting "repos" deletes
    /// what is in "repos.starred" too.
    public var domain: String?
    public var title: String
    public var subtitle: String?
    /// Extra names the item should be found by.
    public var keywords: [String]
    public var icon: Icon
    /// Short label shown at the trailing edge, such as "Contact".
    public var kind: String
    /// When the item stops being found, if it does by itself.
    public var expires: Date?
    /// Whatever its source needs to act on it, kept with it.
    public var info: [String: String]

    public init(
        id: String,
        domain: String? = nil,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        icon: Icon,
        kind: String,
        expires: Date? = nil,
        info: [String: String] = [:]
    ) {
        self.id = id
        self.domain = domain
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.icon = icon
        self.kind = kind
        self.expires = expires
        self.info = info
    }

    /// Whether the item is in `domain`, or in a group within it.
    func isIn(_ domain: String) -> Bool {
        guard let own = self.domain else { return false }
        return own == domain || own.hasPrefix(domain + ".")
    }

    func isExpired(at date: Date) -> Bool {
        expires.map { $0 <= date } ?? false
    }
}

/// A module that has items in the search index.
///
/// Where `candidates` hands the engine a list of commands whenever it is
/// asked, a source tells the index what changed, when it changes: add or
/// replace these items, delete those. The index keeps them, on disk if the
/// source says so, and the search finds them without the source having to
/// do anything, or even to run.
///
/// This is the contract Core Spotlight has with an application, with
/// `reindex` and `actions(for:)` in the place of its index delegate.
/// Extensions will be hosted behind it like any module.
@MainActor
public protocol SearchableSource: Module {
    /// Where the source writes its items. Set by the engine once the index
    /// is open, and nil until then.
    var index: SourceIndex? { get set }

    /// Whether the items are kept from one launch to the next. What is kept
    /// on disk is found the moment Inky starts, and can be read by whoever
    /// can read Inky's files. Private data that macOS guards belongs in
    /// memory.
    var indexStorage: SearchIndex.Storage { get }

    /// Goes up when the source makes its items differently. Items kept
    /// under another version are dropped, and `reindex` is called.
    var indexVersion: Int { get }

    /// The most of its items the search lists for one query, so that a
    /// source of thousands does not crowd out everything else.
    var resultLimit: Int { get }

    /// Called when the index has none of the source's items, or none it can
    /// trust: the first time, after the module was switched on, when the
    /// version changed, when the items are kept in memory and Inky started,
    /// or when what was kept could not be read. The source replaces all of
    /// its items. Until it returns, the index does not count as complete,
    /// and asks again the next time Inky starts.
    func reindex() async

    /// What can be done with an item. The first action runs on Return, the
    /// second on Command-Return. Asked only for the items a search lists.
    func actions(for item: SearchableItem) -> [Action]

    /// The picture of an item whose icon is `Icon.picture`, as the data of
    /// an image file, or nil if it has none. Asked only for the items that
    /// are on screen, so that an item need not carry its picture: a
    /// thousand of them are a lot to hold, and to keep.
    func picture(for itemID: String) async -> Data?
}

public extension SearchableSource {
    var indexVersion: Int { 1 }
    var resultLimit: Int { 5 }
    func picture(for itemID: String) async -> Data? { nil }
}
