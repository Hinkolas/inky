import Foundation

/// Turns a query into ranked sections by asking every enabled provider.
///
/// Candidates are held in memory and matched synchronously, so results for a
/// keystroke are ready in the same frame. The index sits behind this type on
/// purpose: swapping it for a persistent one later does not touch providers.
@MainActor
public final class SearchEngine {
    public let providers: [any Provider]
    public let usage: UsageStore

    /// Consulted on every query, so toggling a provider takes effect at once.
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

    public init(providers: [any Provider], usage: UsageStore) {
        self.providers = providers
        self.usage = usage
        for provider in providers {
            provider.onChange = { [weak self, weak provider] in
                guard let self, let provider else { return }
                Task { await self.reload(provider) }
            }
        }
    }

    // MARK: - Index

    public func reloadAll() async {
        for provider in providers {
            await reload(provider)
        }
    }

    /// Reloads providers whose candidates may have changed behind their back.
    public func reloadStale(now: Date = .now) {
        for provider in providers {
            guard let interval = provider.refreshInterval,
                  now.timeIntervalSince(lastReload[provider.id] ?? .distantPast) > interval
            else { continue }
            lastReload[provider.id] = now
            Task { await reload(provider) }
        }
    }

    private func reload(_ provider: any Provider) async {
        let items = await provider.candidates()
        index[provider.id] = items.map { item in
            Entry(
                item: item,
                title: FuzzyMatcher.Target(item.title),
                keywords: item.keywords.map(FuzzyMatcher.Target.init)
            )
        }
        lastReload[provider.id] = .now
        onChange?()
    }

    // MARK: - Queries

    /// Everything that is available without waiting.
    public func results(for query: String) -> [ResultSection] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return suggestions() }

        var sections: [ResultSection] = []
        for provider in enabledProviders {
            let items = provider.instantResults(for: query)
            if !items.isEmpty {
                sections.append(ResultSection(title: provider.info.title, items: items))
            }
        }

        let pattern = FuzzyMatcher.Pattern(query)
        // "git hub" should still find "GitHub".
        let compact = query.contains(" ")
            ? FuzzyMatcher.Pattern(query.replacingOccurrences(of: " ", with: ""))
            : nil

        var ranked: [(item: ResultItem, score: Double)] = []
        for provider in enabledProviders {
            for entry in index[provider.id] ?? [] {
                guard let match = match(entry, pattern, compact), match >= minimumScore else { continue }
                ranked.append((entry.item, match + usage.boost(for: entry.item.id, query: query)))
            }
        }
        ranked.sort {
            $0.score != $1.score
                ? $0.score > $1.score
                : $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
        }
        if !ranked.isEmpty {
            sections.append(ResultSection(title: "Results", items: ranked.prefix(maxResults).map(\.item)))
        }
        return sections
    }

    /// Results that take time, to be appended below `results(for:)`.
    public func deferredResults(for query: String) async -> [ResultSection] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }

        var sections: [ResultSection] = []
        for provider in enabledProviders {
            if let section = await provider.deferredResults(for: query), !section.items.isEmpty {
                sections.append(section)
            }
        }
        return sections
    }

    public func recordUse(of item: ResultItem, query: String) {
        usage.record(item.id, query: query)
    }

    // MARK: - Private

    private var enabledProviders: [any Provider] {
        providers.filter { isEnabled($0.id) }
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

    /// With nothing typed: what the user picks most, then everything by provider.
    private func suggestions() -> [ResultSection] {
        let providers = enabledProviders
        var used: [(item: ResultItem, frecency: Double)] = []
        for provider in providers {
            for entry in index[provider.id] ?? [] {
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
        for provider in providers {
            let items = (index[provider.id] ?? [])
                .map(\.item)
                .filter { !topIDs.contains($0.id) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !items.isEmpty {
                sections.append(ResultSection(title: provider.info.title, items: items))
            }
        }
        return sections
    }
}
