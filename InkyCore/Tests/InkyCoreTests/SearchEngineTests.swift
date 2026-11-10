import Foundation
import Testing
@testable import InkyCore

@MainActor
private final class StubProvider: Provider {
    let id: String
    let info: ProviderInfo
    var onChange: (@MainActor () -> Void)?
    var titles: [String]
    var instant: [String: String] = [:]

    init(id: String, titles: [String]) {
        self.id = id
        self.titles = titles
        info = ProviderInfo(title: id.capitalized, summary: "", icon: .symbol("star", tint: .gray))
    }

    private func item(_ title: String) -> ResultItem {
        ResultItem(id: "\(id):\(title)", title: title, icon: info.icon, kind: "Stub", actions: [])
    }

    func candidates() async -> [ResultItem] { titles.map(item) }

    func instantResults(for query: String) -> [ResultItem] {
        instant[query].map { [item($0)] } ?? []
    }
}

@MainActor
@Suite struct SearchEngineTests {
    private func titles(_ sections: [ResultSection]) -> [String] {
        sections.flatMap(\.items).map(\.title)
    }

    private func makeEngine(_ providers: StubProvider...) async -> SearchEngine {
        let engine = SearchEngine(providers: providers, usage: UsageStore(fileURL: nil))
        await engine.reloadAll()
        return engine
    }

    @Test func ranksBestMatchFirst() async {
        let engine = await makeEngine(StubProvider(id: "apps", titles: ["Disk Safety", "Safari", "Slack"]))
        #expect(titles(engine.results(for: "saf")) == ["Safari", "Disk Safety"])
    }

    @Test func dropsNoise() async {
        let engine = await makeEngine(StubProvider(id: "apps", titles: ["Safari"]))
        #expect(engine.results(for: "zzz").isEmpty)
    }

    @Test func learnsWhatTheUserPicks() async throws {
        let engine = await makeEngine(StubProvider(id: "apps", titles: ["Kagi Search", "Karabiner", "Keychain Access"]))
        let before = titles(engine.results(for: "k"))
        #expect(before.first != "Keychain Access")

        let keychain = try #require(engine.results(for: "k").flatMap(\.items).first { $0.title == "Keychain Access" })
        engine.recordUse(of: keychain, query: "k")
        #expect(titles(engine.results(for: "k")).first == "Keychain Access")
    }

    @Test func emptyQueryListsSuggestionsThenProviders() async throws {
        let engine = await makeEngine(
            StubProvider(id: "links", titles: ["Zeta", "Alpha"]),
            StubProvider(id: "apps", titles: ["Safari"])
        )
        var sections = engine.results(for: "")
        #expect(sections.map(\.title) == ["Links", "Apps"])
        #expect(sections[0].items.map(\.title) == ["Alpha", "Zeta"])

        engine.recordUse(of: sections[1].items[0], query: "")
        sections = engine.results(for: "  ")
        #expect(sections.map(\.title) == ["Suggestions", "Links"])
        #expect(titles(sections) == ["Safari", "Alpha", "Zeta"])
    }

    @Test func skipsDisabledProviders() async {
        let engine = await makeEngine(
            StubProvider(id: "apps", titles: ["Safari"]),
            StubProvider(id: "links", titles: ["Safari Docs"])
        )
        engine.isEnabled = { $0 != "links" }
        #expect(titles(engine.results(for: "saf")) == ["Safari"])
    }

    @Test func instantResultsComeFirst() async {
        let provider = StubProvider(id: "calc", titles: [])
        provider.instant = ["1+1": "2"]
        let engine = await makeEngine(provider, StubProvider(id: "apps", titles: ["1+1 Notes"]))
        #expect(engine.results(for: "1+1").map(\.title) == ["Calc", "Results"])
    }

    @Test func findsNamesTypedWithASpace() async {
        let engine = await makeEngine(StubProvider(id: "apps", titles: ["GitHub Desktop"]))
        #expect(titles(engine.results(for: "git hub")) == ["GitHub Desktop"])
    }

    @Test func reloadsWhenAProviderChanges() async throws {
        let provider = StubProvider(id: "links", titles: ["Alpha"])
        let engine = await makeEngine(provider)
        await confirmation { changed in
            engine.onChange = { changed() }
            provider.titles = ["Alpha", "Beta"]
            provider.onChange?()
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(titles(engine.results(for: "bet")) == ["Beta"])
    }
}

@MainActor
@Suite struct UsageStoreTests {
    @Test func frecencyGrowsWithUseAndFadesWithTime() {
        let store = UsageStore(fileURL: nil)
        let now = Date.now
        #expect(store.frecency("a", now: now) == 0)

        store.record("a", query: "", at: now)
        let once = store.frecency("a", now: now)
        store.record("a", query: "", at: now)
        #expect(store.frecency("a", now: now) > once)
        #expect(store.frecency("a", now: now.addingTimeInterval(60 * 86_400)) < once)
    }

    @Test func boostsTheQueryAnItemWasPickedFor() {
        let store = UsageStore(fileURL: nil)
        store.record("a", query: "Kag")
        let exact = store.boost(for: "a", query: "kag")
        let related = store.boost(for: "a", query: "ka")
        let unrelated = store.boost(for: "a", query: "xyz")
        #expect(exact > related)
        #expect(related > unrelated)
        #expect(unrelated > 0)
    }

    @Test func persistsAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inky-usage-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        UsageStore(fileURL: url).record("a", query: "q")
        #expect(UsageStore(fileURL: url).frecency("a") > 0)
    }
}

@MainActor
@Suite struct QuicklinkStoreTests {
    @Test func savesUpdatesAndDeletes() {
        let store = QuicklinkStore(fileURL: nil)
        var changes = 0
        store.onChange = { changes += 1 }

        var link = Quicklink(name: "Docs", link: "https://example.com")
        store.save(link)
        link.name = "Documentation"
        store.save(link)
        #expect(store.quicklinks.map(\.name) == ["Documentation"])

        store.delete(link.id)
        #expect(store.quicklinks.isEmpty)
        #expect(changes == 3)
    }

    @Test func seedsStartersOnFirstLaunchOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inky-links-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = QuicklinkStore(fileURL: url)
        #expect(!first.quicklinks.isEmpty)
        first.quicklinks.map(\.id).forEach(first.delete)
        #expect(QuicklinkStore(fileURL: url).quicklinks.isEmpty)
    }

    @Test func summarizesLinks() {
        #expect(QuicklinkProvider.summary(of: "https://www.example.com/search?q={argument}") == "example.com")
        #expect(QuicklinkProvider.summary(of: "~/Downloads") == "~/Downloads")
    }
}
