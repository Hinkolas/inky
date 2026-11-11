import Foundation

/// Turns a query into ranked sections by asking every enabled module.
///
/// Candidates are held in memory and matched synchronously, so results for a
/// keystroke are ready in the same frame. The index sits behind this type on
/// purpose: swapping it for a persistent one later does not touch modules.
@MainActor
public final class SearchEngine {
    public let modules: [any Module]
    public let usage: UsageStore

    /// Consulted on every query, so toggling a module takes effect at once.
    public var isEnabled: @MainActor (String) -> Bool = { _ in true }
    /// Called after the index changed and visible results may be stale.
    public var onChange: (@MainActor () -> Void)?

    public var maxResults = 50
    public var suggestionCount = 6
    /// Matches weaker than this are noise and are dropped.
    public var minimumScore = 0.3

    private struct Entry {
        let item: ResultItem
        let title: FuzzyMatcher.Target
        let keywords: [FuzzyMatcher.Target]
    }

    private var index: [String: [Entry]] = [:]
    private var lastReload: [String: Date] = [:]

    public init(modules: [any Module], usage: UsageStore) {
        self.modules = modules
        self.usage = usage
        for module in modules {
            module.onChange = { [weak self, weak module] in
                guard let self, let module else { return }
                Task { await self.reload(module) }
            }
        }
    }

    // MARK: - Index

    public func reloadAll() async {
        for module in modules {
            await reload(module)
        }
    }

    /// Reloads modules whose candidates may have changed behind their back.
    public func reloadStale(now: Date = .now) {
        for module in modules {
            guard let interval = module.refreshInterval,
                  now.timeIntervalSince(lastReload[module.id] ?? .distantPast) > interval
            else { continue }
            lastReload[module.id] = now
            Task { await reload(module) }
        }
    }

    private func reload(_ module: any Module) async {
        let items = await module.candidates()
        index[module.id] = items.map { item in
            Entry(
                item: item,
                title: FuzzyMatcher.Target(item.title),
                keywords: item.keywords.map(FuzzyMatcher.Target.init)
            )
        }
        lastReload[module.id] = .now
        onChange?()
    }

    // MARK: - Queries

    /// Everything that is available without waiting.
    public func results(for query: String) -> [ResultSection] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return suggestions() }

        var sections: [ResultSection] = []
        for module in enabledModules {
            let items = module.instantResults(for: query)
            if !items.isEmpty {
                sections.append(ResultSection(title: module.info.title, items: items))
            }
        }

        let pattern = FuzzyMatcher.Pattern(query)
        // "git hub" should still find "GitHub".
        let compact = query.contains(" ")
            ? FuzzyMatcher.Pattern(query.replacingOccurrences(of: " ", with: ""))
            : nil

        var ranked: [(item: ResultItem, group: String, score: Double)] = []
        for module in enabledModules {
            for entry in index[module.id] ?? [] {
                guard let match = match(entry, pattern, compact), match >= minimumScore else { continue }
                ranked.append((entry.item, module.info.title, match + usage.boost(for: entry.item.id, query: query)))
            }
        }
        ranked.sort {
            $0.score != $1.score
                ? $0.score > $1.score
                : $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
        }

        // The best match stands alone. The rest follow under the module they
        // came from, and the module holding the next best match goes first.
        var groups: [ResultSection] = []
        for (offset, entry) in ranked.prefix(maxResults).enumerated() {
            if offset == 0 {
                groups.append(ResultSection(title: Self.topHitTitle, items: [entry.item]))
            } else if let existing = groups.firstIndex(where: { $0.title == entry.group }) {
                groups[existing].items.append(entry.item)
            } else {
                groups.append(ResultSection(title: entry.group, items: [entry.item]))
            }
        }
        return sections + groups
    }

    public static let topHitTitle = "Top hit"

    /// Results that take time, to be appended below `results(for:)`.
    public func deferredResults(for query: String) async -> [ResultSection] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }

        var sections: [ResultSection] = []
        for module in enabledModules {
            if let section = await module.deferredResults(for: query), !section.items.isEmpty {
                sections.append(section)
            }
        }
        return sections
    }

    /// Ways to take the query elsewhere, to be listed below everything else.
    public func fallbacks(for query: String) -> ResultSection? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }

        let items = enabledModules.flatMap { $0.fallbackResults(for: query) }
        return items.isEmpty ? nil : ResultSection(title: Self.fallbackTitle(for: query), items: items)
    }

    /// A long query is cut short, so the title still says what the section is.
    static func fallbackTitle(for query: String) -> String {
        let limit = 40
        let shown = query.count > limit
            ? query.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
            : query
        return "Use “\(shown)” with"
    }

    public func recordUse(of item: ResultItem, query: String) {
        usage.record(item.id, query: query)
    }

    // MARK: - Private

    private var enabledModules: [any Module] {
        modules.filter { isEnabled($0.id) }
    }

    private func match(_ entry: Entry, _ pattern: FuzzyMatcher.Pattern, _ compact: FuzzyMatcher.Pattern?) -> Double? {
        var best = FuzzyMatcher.score(pattern, in: entry.title)
        if best == nil, let compact {
            best = FuzzyMatcher.score(compact, in: entry.title).map { $0 * 0.9 }
        }
        for keyword in entry.keywords {
            if let score = FuzzyMatcher.score(pattern, in: keyword).map({ $0 * 0.85 }), score > best ?? 0 {
                best = score
            }
        }
        return best
    }

    /// With nothing typed: what the user picks most, then everything by module.
    private func suggestions() -> [ResultSection] {
        let modules = enabledModules
        var used: [(item: ResultItem, frecency: Double)] = []
        for module in modules {
            for entry in index[module.id] ?? [] {
                let frecency = usage.frecency(entry.item.id)
                if frecency > 0 { used.append((entry.item, frecency)) }
            }
        }
        used.sort { $0.frecency > $1.frecency }
        let top = used.prefix(suggestionCount).map(\.item)
        let topIDs = Set(top.map(\.id))

        var sections: [ResultSection] = []
        if !top.isEmpty {
            sections.append(ResultSection(title: "Suggestions", items: top))
        }
        for module in modules {
            let items = (index[module.id] ?? [])
                .map(\.item)
                .filter { !topIDs.contains($0.id) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !items.isEmpty {
                sections.append(ResultSection(title: module.info.title, items: items))
            }
        }
        return sections
    }
}
