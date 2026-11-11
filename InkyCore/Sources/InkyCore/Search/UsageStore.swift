import Foundation

/// Remembers what was launched, how often, how recently and from which query,
/// so results the user actually picks rise to the top.
@MainActor
public final class UsageStore {
    struct Record: Codable {
        var count: Int
        var lastUsed: Date
        /// How often the item was picked for a given query.
        var queries: [String: Int]
    }

    private var records: [String: Record] = [:]
    private let fileURL: URL?

    /// Pass nil to keep the history in memory only.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        records = (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    public func record(_ itemID: String, query: String, at date: Date = .now) {
        var record = records[itemID] ?? Record(count: 0, lastUsed: date, queries: [:])
        record.count += 1
        record.lastUsed = date

        let key = Self.normalize(query)
        if !key.isEmpty {
            record.queries[key, default: 0] += 1
            if record.queries.count > Self.maxQueriesPerItem,
               let rarest = record.queries.filter({ $0.key != key }).min(by: { $0.value < $1.value }) {
                record.queries[rarest.key] = nil
            }
        }

        records[itemID] = record
        save()
    }

    /// Whether anything about the item is remembered.
    public func hasHistory(_ itemID: String) -> Bool {
        records[itemID] != nil
    }

    /// Forgets that the item was ever picked, so it ranks by its match alone.
    public func forget(_ itemID: String) {
        guard records.removeValue(forKey: itemID) != nil else { return }
        save()
    }

    /// 0...1, combining how often and how recently the item was used.
    public func frecency(_ itemID: String, now: Date = .now) -> Double {
        guard let record = records[itemID] else { return 0 }
        let days = now.timeIntervalSince(record.lastUsed) / 86_400
        let recency: Double = switch days {
        case ..<4: 1
        case ..<14: 0.7
        case ..<31: 0.5
        case ..<90: 0.3
        default: 0.1
        }
        return min(1, log2(1 + Double(record.count)) / 5) * recency
    }

    /// What to add to an item's match score for this query.
    public func boost(for itemID: String, query: String, now: Date = .now) -> Double {
        guard let record = records[itemID] else { return 0 }
        var boost = 0.25 * frecency(itemID, now: now)

        let key = Self.normalize(query)
        if record.queries[key] != nil {
            boost += 0.6
        } else if record.queries.keys.contains(where: { $0.hasPrefix(key) || key.hasPrefix($0) }) {
            boost += 0.3
        }
        return boost
    }

    private static let maxQueriesPerItem = 8

    private static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
