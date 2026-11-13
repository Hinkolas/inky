import Foundation
import Testing
@testable import InkyCore

private func item(_ id: String, _ title: String? = nil, domain: String? = nil, expires: Date? = nil) -> SearchableItem {
    SearchableItem(
        id: id, domain: domain, title: title ?? id, subtitle: "sub", keywords: ["key \(id)"],
        icon: .picture(source: "source", id: id, fallback: .favicon(host: "example.com", fallback: .symbol("star", tint: .blue))),
        kind: "Thing",
        expires: expires, info: ["a": "b"]
    )
}

@MainActor
private final class StubSource: SearchableSource {
    let id: String
    let info: ModuleInfo
    var onChange: (@MainActor () -> Void)?
    var index: SourceIndex?
    var indexStorage = SearchIndex.Storage.memory
    var indexVersion = 1
    var resultLimit = 5
    var titles: [String]
    var commands: [String] = []
    private(set) var reindexes = 0

    init(id: String, titles: [String]) {
        self.id = id
        self.titles = titles
        info = ModuleInfo(title: id.capitalized, summary: "", icon: .symbol("star", tint: .gray))
    }

    func candidates() async -> [ResultItem] {
        commands.map { ResultItem(id: "\(id):command:\($0)", title: $0, icon: info.icon, kind: "Command", actions: []) }
    }

    func reindex() async {
        reindexes += 1
        index?.replaceAll(with: titles.map { item($0) })
    }

    func actions(for item: SearchableItem) -> [Action] {
        [Action("Open \(item.title)", symbol: "star") { _ in }]
    }
}

@MainActor
@Suite struct SearchIndexTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("InkyIndexTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    private func opened(_ index: SearchIndex, _ storage: SearchIndex.Storage = .memory, version: Int = 1) async -> SourceIndex {
        _ = await index.open([SearchIndex.Registration(id: "source", storage: storage, version: version)])
        return SourceIndex(index, source: "source")
    }

    @Test func addsReplacesAndDeletesItems() async {
        let source = await opened(SearchIndex(fileURL: nil))
        source.index([item("a"), item("b"), item("c")])
        #expect(source.count == 3)

        source.index([item("a", "Renamed")])
        #expect(source.count == 3)
        #expect(source.item("a")?.title == "Renamed")

        source.delete(ids: ["b", "unknown"])
        #expect(source.count == 2)
        source.deleteAll()
        #expect(source.count == 0)
    }

    @Test func deletesAGroupWithTheGroupsInIt() async {
        let source = await opened(SearchIndex(fileURL: nil))
        source.index([
            item("1", domain: "repos"), item("2", domain: "repos.starred"), item("3", domain: "reposts"),
            item("4", domain: "people"), item("5"),
        ])
        source.delete(domains: ["repos"])
        #expect(Set(source.index.items(of: "source").map(\.id)) == ["3", "4", "5"])
    }

    @Test func appliesABatchInTheOrderItIsWritten() async {
        let source = await opened(SearchIndex(fileURL: nil))
        source.index([item("old")])
        source.update { batch in
            batch.index([item("a"), item("b")])
            batch.deleteAll()
            batch.index([item("c"), item("d")])
            batch.delete(ids: ["d"])
            batch.state = Data("token 1".utf8)
        }
        #expect(source.index.items(of: "source").map(\.id) == ["c"])
        #expect(source.state == Data("token 1".utf8))
    }

    @Test func refusesABatchForAnotherStateThanTheOneKept() async {
        let source = await opened(SearchIndex(fileURL: nil))
        #expect(source.update(expecting: nil) { batch in
            batch.index([item("a")])
            batch.state = Data("1".utf8)
        })
        // The source thinks the index is somewhere it is not.
        #expect(!source.update(expecting: Data("0".utf8)) { batch in
            batch.deleteAll()
            batch.state = Data("2".utf8)
        })
        #expect(source.count == 1)
        #expect(source.state == Data("1".utf8))

        #expect(source.update(expecting: Data("1".utf8)) { $0.state = Data("2".utf8) })
        #expect(source.state == Data("2".utf8))
    }

    @Test func aBatchWithoutAStateLeavesTheOneKept() async {
        let source = await opened(SearchIndex(fileURL: nil))
        source.replaceAll(with: [item("a")], state: Data("1".utf8))
        source.index([item("b")])
        #expect(source.state == Data("1".utf8))
    }

    @Test func takesNothingFromASourceThatIsClosedOrUnknown() async {
        let index = SearchIndex(fileURL: nil)
        let source = await opened(index)
        source.index([item("a")])
        index.close("source")
        #expect(source.count == 0)
        #expect(!source.update { $0.index([item("b")]) })
        #expect(source.count == 0)

        index.reopen("source")
        #expect(source.update { $0.index([item("b")]) })
        #expect(!SourceIndex(index, source: "nobody").update { $0.index([item("c")]) })
    }

    @Test func saysWhenItemsChanged() async {
        let index = SearchIndex(fileURL: nil)
        let source = await opened(index)
        var changes = 0
        index.onChange = { changes += 1 }
        let revision = index.revision
        source.index([item("a")])
        source.delete(ids: ["a"])
        #expect(changes == 2)
        #expect(index.revision == revision + 2)
    }

    // MARK: - On disk

    @Test func keepsWhatASourceOnDiskIndexed() async {
        let file = temporaryFile()
        do {
            let index = SearchIndex(fileURL: file)
            #expect(index.isPersistent)
            let stale = await index.open([SearchIndex.Registration(id: "source", storage: .disk)])
            // Never indexed: there is nothing to trust yet.
            #expect(stale == ["source"])
            let source = SourceIndex(index, source: "source")
            source.replaceAll(with: [item("a"), item("b"), item("c")], state: Data("token".utf8))
            source.delete(ids: ["b"])
            source.index([item("a", "Renamed")])
            index.markComplete("source")
            await index.flush()
        }

        let index = SearchIndex(fileURL: file)
        let stale = await index.open([SearchIndex.Registration(id: "source", storage: .disk)])
        #expect(stale.isEmpty)
        let kept = index.items(of: "source").sorted { $0.id < $1.id }
        #expect(kept == [item("a", "Renamed"), item("c")])
        #expect(index.state(of: "source") == Data("token".utf8))
    }

    @Test func doesNotTrustWhatWasNeverIndexedToTheEnd() async {
        let file = temporaryFile()
        do {
            let index = SearchIndex(fileURL: file)
            let source = await opened(index, .disk)
            source.index([item("a")])
            await index.flush()
        }
        let index = SearchIndex(fileURL: file)
        #expect(await index.open([SearchIndex.Registration(id: "source", storage: .disk)]) == ["source"])
        #expect(index.count(of: "source") == 0)
    }

    @Test func dropsWhatWasMadeUnderAnotherVersion() async {
        let file = temporaryFile()
        do {
            let index = SearchIndex(fileURL: file)
            let source = await opened(index, .disk)
            source.index([item("a")])
            index.markComplete("source")
            await index.flush()
        }
        let index = SearchIndex(fileURL: file)
        #expect(await index.open([SearchIndex.Registration(id: "source", storage: .disk, version: 2)]) == ["source"])
        #expect(index.count(of: "source") == 0)
    }

    @Test func keepsNothingOfASourceInMemory() async {
        let file = temporaryFile()
        do {
            let index = SearchIndex(fileURL: file)
            let source = await opened(index, .memory)
            source.index([item("a")])
            index.markComplete("source")
            await index.flush()
        }
        let index = SearchIndex(fileURL: file)
        // Not as a source in memory, and not as one that is on disk now.
        #expect(await index.open([SearchIndex.Registration(id: "source", storage: .memory)]) == ["source"])
        #expect(index.count(of: "source") == 0)
        let again = SearchIndex(fileURL: file)
        #expect(await again.open([SearchIndex.Registration(id: "source", storage: .disk)]) == ["source"])
    }

    @Test func deletesWhatAClosedOrForgottenSourceKept() async {
        let file = temporaryFile()
        do {
            let index = SearchIndex(fileURL: file)
            _ = await index.open([
                SearchIndex.Registration(id: "closed", storage: .disk),
                SearchIndex.Registration(id: "gone", storage: .disk),
                SearchIndex.Registration(id: "kept", storage: .disk),
            ])
            for id in ["closed", "gone", "kept"] {
                SourceIndex(index, source: id).index([item("a")])
                index.markComplete(id)
            }
            index.close("closed")
            await index.flush()
        }
        do {
            // "gone" is not a source any longer: an extension that was removed.
            let index = SearchIndex(fileURL: file)
            let stale = await index.open([
                SearchIndex.Registration(id: "closed", storage: .disk),
                SearchIndex.Registration(id: "kept", storage: .disk),
            ])
            #expect(stale == ["closed"])
            #expect(index.count(of: "kept") == 1)
            await index.flush()
        }
        let index = SearchIndex(fileURL: file)
        #expect(await index.open([SearchIndex.Registration(id: "gone", storage: .disk)]) == ["gone"])
    }

    @Test func leavesOutWhatHasExpired() async {
        let file = temporaryFile()
        do {
            let index = SearchIndex(fileURL: file)
            let source = await opened(index, .disk)
            source.index([item("old", expires: Date(timeIntervalSinceNow: -60)), item("new", expires: Date(timeIntervalSinceNow: 3600))])
            index.markComplete("source")
            await index.flush()
        }
        let index = SearchIndex(fileURL: file)
        #expect(await index.open([SearchIndex.Registration(id: "source", storage: .disk)]).isEmpty)
        #expect(index.items(of: "source").map(\.id) == ["new"])
    }

    @Test func worksWithoutAFileItCanOpen() async {
        let index = SearchIndex(fileURL: URL(fileURLWithPath: "/dev/null/nowhere/index.sqlite"))
        #expect(!index.isPersistent)
        let source = await opened(index, .disk)
        source.index([item("a")])
        #expect(source.count == 1)
    }

    // MARK: - In the search

    private func titles(_ sections: [ResultSection]) -> [String] {
        sections.flatMap(\.items).map(\.title)
    }

    @Test func findsItemsAmongTheCommands() async {
        let people = StubSource(id: "people", titles: ["Thomas Becker", "Thea Lind", "Sam Finder"])
        people.commands = ["Thesaurus"]
        let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil))
        await engine.reloadAll()

        let sections = engine.results(for: "thea")
        #expect(Set(titles(sections)) == ["Thea Lind", "Thesaurus"])
        let thea = sections.flatMap(\.items).first { $0.title == "Thea Lind" }
        #expect(thea?.id == "people:Thea Lind")
        #expect(thea?.kind == "Thing")
        // What can be done with it, its source says.
        #expect(thea?.actions.map(\.title) == ["Open Thea Lind"])
        // By a keyword as well.
        #expect(titles(engine.results(for: "key sam")) == ["Sam Finder"])
    }

    @Test func findsItemsOnlyByAMatchThatIsNotScattered() async {
        let people = StubSource(id: "people", titles: ["Richard Hart", "Chiara Romano"])
        people.commands = ["Chiara Romano"]
        let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil))
        await engine.reloadAll()

        // The letters are in both names. A command is found by them
        // wherever they are, an item where they begin a word.
        let found = engine.results(for: "har").flatMap(\.items)
        #expect(found.map(\.id) == ["people:Richard Hart", "people:command:Chiara Romano"])
    }

    @Test func itemsAreNotCommands() async throws {
        let people = StubSource(id: "people", titles: ["Thomas Becker"])
        people.commands = ["Thesaurus"]
        let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil))
        await engine.reloadAll()

        let thomas = try #require(engine.results(for: "thomas").first?.items.first)
        #expect(!engine.isCommand(thomas))
        #expect(engine.commands(in: "people").map(\.title) == ["Thesaurus"])
        // With nothing typed, the lists by module are of commands.
        #expect(titles(engine.results(for: "")) == ["Thesaurus"])
    }

    @Test func listsOnlyTheBestOfASource() async {
        let people = StubSource(id: "people", titles: (1...40).map { "Anna \($0)" } + ["Anna"])
        people.resultLimit = 3
        let apps = StubModuleForIndex(titles: ["Annotate", "Antenna"])
        let engine = SearchEngine(modules: [people, apps], usage: UsageStore(fileURL: nil))
        await engine.reloadAll()

        let found = titles(engine.results(for: "ann"))
        #expect(found.filter { $0.hasPrefix("Anna") }.count == 3)
        #expect(found.contains("Anna"))
        #expect(found.contains("Annotate"))
        #expect(found.contains("Antenna"))
    }

    @Test func whatIsPickedOftenRanksHigherAndIsSuggested() async throws {
        let people = StubSource(id: "people", titles: ["Thomas Becker", "Thomas Albrecht"])
        let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil))
        await engine.reloadAll()

        #expect(titles(engine.results(for: "thomas")).first == "Thomas Albrecht")
        let becker = try #require(engine.results(for: "thomas").flatMap(\.items).first { $0.title == "Thomas Becker" })
        #expect(!engine.hasRanking(becker))
        for _ in 0..<3 { engine.recordUse(of: becker, query: "thomas") }

        #expect(titles(engine.results(for: "thomas")).first == "Thomas Becker")
        #expect(engine.hasRanking(becker))
        let suggestions = engine.results(for: "")
        #expect(suggestions.first?.title == "Suggestions")
        #expect(titles(suggestions) == ["Thomas Becker"])
    }

    @Test func asksASourceForItsItemsOnlyWhenItHasNone() async {
        let people = StubSource(id: "people", titles: ["Thomas"])
        let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil))
        #expect(people.index == nil)
        await engine.reloadAll()
        await engine.reloadAll()
        #expect(people.reindexes == 1)
        #expect(people.index?.count == 1)
    }

    @Test func aSourceOnDiskIsFoundWithoutBeingAsked() async {
        let file = temporaryFile()
        do {
            let people = StubSource(id: "people", titles: ["Thomas"])
            people.indexStorage = .disk
            let index = SearchIndex(fileURL: file)
            let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil), index: index)
            await engine.reloadAll()
            #expect(people.reindexes == 1)
            await index.flush()
        }
        let people = StubSource(id: "people", titles: ["Somebody else"])
        people.indexStorage = .disk
        let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil), index: SearchIndex(fileURL: file))
        await engine.reloadAll()
        #expect(people.reindexes == 0)
        #expect(titles(engine.results(for: "thomas")) == ["Thomas"])
    }

    @Test func deletesTheItemsOfAModuleThatIsSwitchedOff() async {
        let people = StubSource(id: "people", titles: ["Thomas"])
        let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil))
        var enabled = true
        engine.isEnabled = { _ in enabled }
        await engine.reloadAll()
        #expect(titles(engine.results(for: "thomas")) == ["Thomas"])

        enabled = false
        engine.modulesDidChange()
        #expect(engine.results(for: "thomas").isEmpty)
        #expect(engine.index.count(of: "people") == 0)
        // Nor is anything taken from it while it is off.
        people.index?.index([item("Thomas")])
        #expect(engine.index.count(of: "people") == 0)

        enabled = true
        engine.modulesDidChange()
        for _ in 0..<50 where people.reindexes < 2 { await Task.yield() }
        #expect(people.reindexes == 2)
        #expect(titles(engine.results(for: "thomas")) == ["Thomas"])
    }

    @Test func aModuleThatIsOffIsNotAskedForItsItems() async {
        let people = StubSource(id: "people", titles: ["Thomas"])
        let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil))
        engine.isEnabled = { _ in false }
        await engine.reloadAll()
        #expect(people.reindexes == 0)
        #expect(engine.index.count(of: "people") == 0)
    }

    @Test func doesNotFindWhatHasExpired() async {
        let people = StubSource(id: "people", titles: [])
        let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil))
        await engine.reloadAll()
        people.index?.index([
            item("Thomas old", expires: Date(timeIntervalSinceNow: -1)),
            item("Thomas new", expires: Date(timeIntervalSinceNow: 3600)),
        ])
        #expect(titles(engine.results(for: "thomas")) == ["Thomas new"])
    }

    @Test func tellsTheLauncherWhenItemsChange() async {
        let people = StubSource(id: "people", titles: [])
        let engine = SearchEngine(modules: [people], usage: UsageStore(fileURL: nil))
        await engine.reloadAll()
        var changes = 0
        engine.onChange = { changes += 1 }
        people.index?.index([item("Thomas")])
        #expect(changes == 1)
    }
}

/// A module of commands only, next to a source.
@MainActor
private final class StubModuleForIndex: Module {
    let id = "apps"
    let info = ModuleInfo(title: "Apps", summary: "", icon: .symbol("star", tint: .gray))
    var onChange: (@MainActor () -> Void)?
    let titles: [String]

    init(titles: [String]) {
        self.titles = titles
    }

    func candidates() async -> [ResultItem] {
        titles.map { ResultItem(id: "apps:\($0)", title: $0, icon: info.icon, kind: "App", actions: []) }
    }
}
