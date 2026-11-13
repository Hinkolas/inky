import Foundation
import Observation

/// Turns a query into ranked sections by asking every enabled module.
///
/// Candidates are held in memory and matched synchronously, so results for a
/// keystroke are ready in the same frame. So are the items of the search
/// index, which modules that are a `SearchableSource` write to: they are
/// ranked together with the candidates, but are not commands.
@MainActor
@Observable
public final class SearchEngine {
    public let modules: [any Module]
    public let usage: UsageStore
    /// Which commands the user chose as fallbacks.
    public let fallbackStore: FallbackStore
    /// Which commands the user switched off, and their hotkeys.
    public let commandStore: CommandStore
    /// The items that are found without being commands.
    public let index: SearchIndex

    /// Consulted on every query, so toggling a module takes effect at once.
    @ObservationIgnored public var isEnabled: @MainActor (String) -> Bool = { _ in true }
    /// Called after the index changed and visible results may be stale.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    @ObservationIgnored public var maxResults = 50
    @ObservationIgnored public var suggestionCount = 6
    /// Matches weaker than this are noise and are dropped.
    @ObservationIgnored public var minimumScore = 0.3
    /// What an item of the index has to match by. Commands are few, and
    /// worth finding by a loose abbreviation. Items are many, and a few
    /// letters are somewhere in most names: those are only found where what
    /// is typed begins a word, or is nearly in one piece.
    @ObservationIgnored public var itemMinimumScore = 0.55

    private struct Entry {
        let item: ResultItem
        let title: FuzzyMatcher.Target
        let keywords: [FuzzyMatcher.Target]
    }

    /// The candidates of each module. Observed, so that settings list the
    /// commands as they are loaded.
    private var candidates: [String: [Entry]] = [:]
    /// The modules that have items in the search index.
    @ObservationIgnored private let sources: [any SearchableSource]
    /// False until the index has read what was kept.
    @ObservationIgnored private var isIndexOpen = false
    /// The sources that are to index everything anew.
    @ObservationIgnored private var staleSources: Set<String> = []
    @ObservationIgnored private var isReindexing = false
    @ObservationIgnored private var lastReload: [String: Date] = [:]
    /// How many times each module was asked for its candidates.
    @ObservationIgnored private var reloads: [String: Int] = [:]
    /// The ids in `index`, of every module.
    @ObservationIgnored private var rankedIDs: Set<String> = []
    /// The candidates of each module that can be fallback commands. Observed,
    /// so that settings list them as they are loaded.
    private var fallbackIndex: [String: [ResultItem]] = [:]

    /// Without `fallbacks`, `commands` or `index`, the choice of fallback
    /// commands, what is decided about single commands, or the items of the
    /// search index are kept in memory only.
    public init(
        modules: [any Module],
        usage: UsageStore,
        fallbacks: FallbackStore? = nil,
        commands: CommandStore? = nil,
        index: SearchIndex? = nil
    ) {
        self.modules = modules
        self.usage = usage
        fallbackStore = fallbacks ?? FallbackStore(fileURL: nil)
        commandStore = commands ?? CommandStore(fileURL: nil)
        self.index = index ?? SearchIndex(fileURL: nil)
        sources = modules.compactMap { $0 as? any SearchableSource }
        self.index.onChange = { [weak self] in self?.onChange?() }
        for module in modules {
            module.onChange = { [weak self, weak module] in
                guard let self, let module else { return }
                Task { await self.reload(module) }
            }
        }
    }

    // MARK: - Index

    public func reloadAll() async {
        await openIndex()
        for module in modules {
            await reload(module)
        }
        await reindexStaleSources()
    }

    /// Reads the items that were kept, the first time, and hands every
    /// source its part of the index.
    private func openIndex() async {
        guard !isIndexOpen else { return }
        isIndexOpen = true
        staleSources = await index.open(sources.map {
            SearchIndex.Registration(id: $0.id, storage: $0.indexStorage, version: $0.indexVersion)
        })
        for source in sources {
            // The items of a module that is off are neither kept nor taken.
            if !isEnabled(source.id) {
                index.close(source.id)
                staleSources.insert(source.id)
            }
            source.index = SourceIndex(index, source: source.id)
        }
        onChange?()
    }

    /// Has the sources index everything anew that the index has nothing
    /// of, or nothing it can trust.
    private func reindexStaleSources() async {
        guard isIndexOpen, !isReindexing else { return }
        isReindexing = true
        defer { isReindexing = false }
        while let source = sources.first(where: { staleSources.contains($0.id) && isEnabled($0.id) }) {
            staleSources.remove(source.id)
            await source.reindex()
            // Switched off meanwhile, what it indexed was not taken.
            if isEnabled(source.id) {
                index.markComplete(source.id)
            } else {
                staleSources.insert(source.id)
            }
        }
    }

    /// Call when a module was switched on or off. The items of one that is
    /// off are deleted, not just left out: they are the user's data. One
    /// that is on again indexes them anew.
    public func modulesDidChange() {
        guard isIndexOpen else { return }
        for source in sources {
            if isEnabled(source.id) {
                index.reopen(source.id)
            } else if !staleSources.contains(source.id) {
                index.close(source.id)
                staleSources.insert(source.id)
            }
        }
        Task { await reindexStaleSources() }
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
        let reload = reloads[module.id, default: 0] + 1
        reloads[module.id] = reload
        let items = await module.candidates()
        // What was asked for later knows better, and is not overwritten
        // should this have taken longer.
        guard reloads[module.id] == reload else { return }
        candidates[module.id] = items.map { item in
            Entry(
                item: item,
                title: FuzzyMatcher.Target(item.title),
                keywords: item.keywords.map(FuzzyMatcher.Target.init)
            )
        }
        fallbackIndex[module.id] = items.filter(\.canBeFallback)
        rankedIDs = Set(candidates.values.joined().map(\.item.id))
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
            for entry in candidates[module.id] ?? [] where commandStore.isEnabled(entry.item.id) {
                guard let match = match(entry.title, entry.keywords, pattern, compact), match >= minimumScore else { continue }
                ranked.append((entry.item, module.info.title, match + usage.boost(for: entry.item.id, query: query)))
            }
        }
        // Items of the index are ranked like commands, by how well they match
        // and how often they are picked. Of each source only its best are
        // listed, and only those are asked for their actions.
        let now = Date.now
        for source in sources where isEnabled(source.id) {
            var found: [(item: SearchableItem, score: Double)] = []
            for entry in index.entries(of: source.id) ?? [:].values where !entry.item.isExpired(at: now) {
                guard let match = match(entry.title, entry.keywords, pattern, compact), match >= itemMinimumScore else { continue }
                let id = Self.resultID(of: entry.item.id, from: source.id)
                found.append((entry.item, match + usage.boost(for: id, query: query)))
            }
            found.sort { Self.ranksBefore(($0.score, $0.item.title, $0.item.id), ($1.score, $1.item.title, $1.item.id)) }
            for entry in found.prefix(source.resultLimit) {
                ranked.append((resultItem(for: entry.item, of: source), source.info.title, entry.score))
            }
        }
        ranked.sort { Self.ranksBefore(($0.score, $0.item.title, $0.item.id), ($1.score, $1.item.title, $1.item.id)) }

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

        let items = chosenFallbacks().map(\.asFallback)
        return items.isEmpty ? nil : ResultSection(title: Self.fallbackTitle(for: query), items: items)
    }

    /// Every command that can be a fallback, under the module it comes from.
    /// One that is switched off cannot.
    public func fallbackCandidates() -> [ResultSection] {
        enabledModules.compactMap { module in
            let items = (fallbackIndex[module.id] ?? []).filter { commandStore.isEnabled($0.id) }
            return items.isEmpty ? nil : ResultSection(title: module.info.title, items: items)
        }
    }

    /// The commands the user chose as fallbacks, first choice first. A choice
    /// whose command is not there, as when its module is off, is left out.
    public func chosenFallbacks() -> [ResultItem] {
        let candidates = fallbackCandidates().flatMap(\.items)
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return fallbackStore.ids.compactMap { byID[$0] }
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

    /// Whether what the user picked has moved the item up, in the results
    /// and the suggestions. Only items that are ranked can be.
    public func hasRanking(_ item: ResultItem) -> Bool {
        usage.hasHistory(item.id) && (rankedIDs.contains(item.id) || isIndexed(item.id))
    }

    /// Lets the item rank by how well it matches again.
    public func resetRanking(of item: ResultItem) {
        usage.forget(item.id)
    }

    // MARK: - Commands

    /// Every command of a module by name, those that are switched off too.
    public func commands(in moduleID: String) -> [ResultItem] {
        (candidates[moduleID] ?? [])
            .map(\.item)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Whether the item is a command: something a module lists, which the
    /// user can switch off or give a hotkey.
    public func isCommand(_ item: ResultItem) -> Bool {
        rankedIDs.contains(item.id)
    }

    /// The command with this id, if it can be run: it is there, and neither
    /// it nor its module is switched off.
    public func command(withID id: String) -> ResultItem? {
        guard commandStore.isEnabled(id) else { return nil }
        return item(withID: id, in: enabledModules)
    }

    /// The command with this id, whether it can be run or not.
    public func item(withID id: String) -> ResultItem? {
        item(withID: id, in: modules)
    }

    private func item(withID id: String, in modules: [any Module]) -> ResultItem? {
        for module in modules {
            if let entry = candidates[module.id]?.first(where: { $0.item.id == id }) { return entry.item }
        }
        return nil
    }

    // MARK: - Private

    private var enabledModules: [any Module] {
        modules.filter { isEnabled($0.id) }
    }

    /// The better score first, then by name. The id decides between two of
    /// one name, so that they do not change places from one key to the next.
    private static func ranksBefore(
        _ a: (score: Double, title: String, id: String), _ b: (score: Double, title: String, id: String)
    ) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let order = a.title.localizedStandardCompare(b.title)
        return order != .orderedSame ? order == .orderedAscending : a.id < b.id
    }

    /// The id an item of the index has as a result. Usage is keyed by it.
    public static func resultID(of itemID: String, from sourceID: String) -> String {
        "\(sourceID):\(itemID)"
    }

    /// An item of the index as the result it is in a search, with what its
    /// source offers to do with it: for whatever lists a source's items
    /// itself. Nil if the module is not a source, or is switched off.
    public func result(for item: SearchableItem, from sourceID: String) -> ResultItem? {
        sources.first { $0.id == sourceID && isEnabled($0.id) }.map { resultItem(for: item, of: $0) }
    }

    /// The picture a source has of one of its items, for an `Icon.picture`.
    /// Nil if there is none, or the module is not a source or switched off.
    public func picture(of itemID: String, from sourceID: String) async -> Data? {
        guard let source = sources.first(where: { $0.id == sourceID && isEnabled($0.id) }) else { return nil }
        return await source.picture(for: itemID)
    }

    /// An item of the index as a row of the launcher, with what its source
    /// offers to do with it.
    private func resultItem(for item: SearchableItem, of source: any SearchableSource) -> ResultItem {
        ResultItem(
            id: Self.resultID(of: item.id, from: source.id),
            title: item.title,
            subtitle: item.subtitle,
            icon: item.icon,
            kind: item.kind,
            keywords: item.keywords,
            actions: source.actions(for: item)
        )
    }

    /// Whether the result is an item of the index.
    private func isIndexed(_ id: String) -> Bool {
        sources.contains { source in
            id.hasPrefix(source.id + ":") && index.item(String(id.dropFirst(source.id.count + 1)), of: source.id) != nil
        }
    }

    private func match(
        _ title: FuzzyMatcher.Target,
        _ keywords: [FuzzyMatcher.Target],
        _ pattern: FuzzyMatcher.Pattern,
        _ compact: FuzzyMatcher.Pattern?
    ) -> Double? {
        var best = FuzzyMatcher.score(pattern, in: title)
        if best == nil, let compact {
            best = FuzzyMatcher.score(compact, in: title).map { $0 * 0.9 }
        }
        for keyword in keywords {
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
            for entry in candidates[module.id] ?? [] where commandStore.isEnabled(entry.item.id) {
                let frecency = usage.frecency(entry.item.id)
                if frecency > 0 { used.append((entry.item, frecency)) }
            }
        }
        // An item of the index that is picked often is suggested like a
        // command. The lists by module below are of commands only.
        let now = Date.now
        for source in sources where isEnabled(source.id) {
            for entry in index.entries(of: source.id) ?? [:].values where !entry.item.isExpired(at: now) {
                let frecency = usage.frecency(Self.resultID(of: entry.item.id, from: source.id))
                if frecency > 0 { used.append((resultItem(for: entry.item, of: source), frecency)) }
            }
        }
        used.sort { $0.frecency != $1.frecency ? $0.frecency > $1.frecency : $0.item.id < $1.item.id }
        let top = used.prefix(suggestionCount).map(\.item)
        let topIDs = Set(top.map(\.id))

        var sections: [ResultSection] = []
        if !top.isEmpty {
            sections.append(ResultSection(title: "Suggestions", items: top))
        }
        for module in modules {
            let items = (candidates[module.id] ?? [])
                .map(\.item)
                .filter { !topIDs.contains($0.id) && commandStore.isEnabled($0.id) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !items.isEmpty {
                sections.append(ResultSection(title: module.info.title, items: items))
            }
        }
        return sections
    }
}
