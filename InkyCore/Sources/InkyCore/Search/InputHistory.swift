import Foundation
import Observation

/// Something that was typed into the launcher: the search, and what went
/// into the arguments of the result it found.
public struct InputEntry: Codable, Sendable, Equatable {
    public var query: String
    /// One value per argument of the result, or none if nothing was typed
    /// into them.
    public var arguments: [String]
    /// The result that was selected, which the arguments belong to.
    public var itemID: String?
    /// How often it was run. Typed and put away again does not count.
    public var count: Int
    public var lastUsed: Date

    public init(query: String, arguments: [String] = [], itemID: String? = nil, count: Int = 0, lastUsed: Date = .now) {
        self.query = query
        self.arguments = arguments
        self.itemID = itemID
        self.count = count
        self.lastUsed = lastUsed
    }

    private enum CodingKeys: String, CodingKey {
        case query, arguments, itemID = "item", count, lastUsed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decode(String.self, forKey: .query)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        itemID = try container.decodeIfPresent(String.self, forKey: .itemID)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
    }

    /// Most searches have no arguments. The file says so by leaving them out.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query, forKey: .query)
        if !arguments.isEmpty { try container.encode(arguments, forKey: .arguments) }
        try container.encodeIfPresent(itemID, forKey: .itemID)
        try container.encode(count, forKey: .count)
        try container.encode(lastUsed, forKey: .lastUsed)
    }

    /// What two entries have in common that are the same thing typed twice.
    fileprivate var key: String {
        ([query] + arguments).map { $0.lowercased() }.joined(separator: "\u{1F}")
    }
}

/// What was typed into the launcher lately, newest first, kept as a JSON
/// file so that the arrow keys can bring it back.
///
/// It is there to type something again, not to say what happened when: the
/// same thing typed again is not listed twice, but moves to the front.
@MainActor
@Observable
public final class InputHistory {
    public private(set) var entries: [InputEntry] = []

    /// How many entries are kept. With none, nothing is remembered.
    public var limit: Int {
        didSet {
            guard limit != oldValue, entries.count > max(0, limit) else { return }
            entries.removeLast(entries.count - max(0, limit))
            write()
        }
    }

    @ObservationIgnored private let fileURL: URL?

    /// Pass nil to keep the history in memory only.
    public init(fileURL: URL?, limit: Int = 100) {
        self.fileURL = fileURL
        self.limit = limit
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([InputEntry].self, from: data)) ?? []
        if entries.count > max(0, limit) {
            entries.removeLast(entries.count - max(0, limit))
            write()
        }
    }

    /// Puts what was typed at the front. `submitted` says that it was run,
    /// not just typed. A search of nothing but spaces is not kept.
    public func record(
        query: String,
        arguments: [String] = [],
        itemID: String? = nil,
        submitted: Bool = false,
        at date: Date = .now
    ) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard limit > 0, !query.isEmpty else { return }
        var arguments = arguments.map { $0.trimmingCharacters(in: .whitespaces) }
        if arguments.allSatisfy(\.isEmpty) { arguments = [] }

        var entry = InputEntry(query: query, arguments: arguments, itemID: itemID, lastUsed: date)
        if let index = entries.firstIndex(where: { $0.key == entry.key }) {
            let known = entries.remove(at: index)
            entry.count = known.count
            entry.itemID = itemID ?? known.itemID
        }
        if submitted { entry.count += 1 }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        write()
    }

    public func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        write()
    }

    private func write() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        // What was typed is nobody else's to read, from the moment it is
        // there: written under another name, and then moved into place.
        let draft = fileURL.appendingPathExtension("new")
        try? FileManager.default.removeItem(at: draft)
        guard FileManager.default.createFile(atPath: draft.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(draft.path, fileURL.path) != 0 {
            try? FileManager.default.removeItem(at: draft)
        }
    }
}
