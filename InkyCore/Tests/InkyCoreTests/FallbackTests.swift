import Foundation
import Testing
@testable import InkyCore

/// A module of something other than quicklinks, to show that any command
/// with one argument will do.
@MainActor
private final class AskModule: Module {
    let id = "ask"
    let info = ModuleInfo(title: "Ask", summary: "", icon: .symbol("sparkles", tint: .pink))
    var onChange: (@MainActor () -> Void)?

    /// What the commands were run with.
    private(set) var asked: [[String]] = []

    func candidates() async -> [ResultItem] {
        [
            command("ask:ai", "Ask AI", arguments: [Argument(name: "Question")]),
            command("ask:history", "Show History", arguments: []),
            command("ask:translate", "Translate", arguments: [Argument(name: "Text"), Argument(name: "Language")]),
        ]
    }

    private func command(_ id: String, _ title: String, arguments: [Argument]) -> ResultItem {
        ResultItem(
            id: id,
            title: title,
            icon: info.icon,
            kind: "Command",
            arguments: arguments,
            actions: [Action(title, symbol: "sparkles", usesArguments: true) { [weak self] in self?.asked.append($0.arguments) }]
        )
    }
}

@MainActor
@Suite struct FallbackTests {
    private func search(_ name: String) -> Quicklink {
        Quicklink(name: name, link: "https://example.com/\(name)?q={argument name=\"Query\"}")
    }

    private func makeStore(_ quicklinks: Quicklink...) -> QuicklinkStore {
        let store = QuicklinkStore(fileURL: nil)
        quicklinks.forEach(store.save)
        return store
    }

    /// An engine over the quicklinks and the commands of `AskModule`, with
    /// the named ones chosen as fallbacks.
    private func makeEngine(_ store: QuicklinkStore, fallbacks: [String]) async -> SearchEngine {
        let chosen = fallbacks.map { name in store.quicklinks.first { $0.name == name }?.itemID ?? name }
        let engine = SearchEngine(
            modules: [QuicklinkModule(store: store), AskModule()],
            usage: UsageStore(fileURL: nil),
            fallbacks: FallbackStore(fileURL: nil, initial: chosen)
        )
        await engine.reloadAll()
        return engine
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inky-\(UUID().uuidString).json")
    }

    // MARK: - What can be a fallback

    @Test func anyCommandWithOneArgumentCanBeAFallback() async {
        let store = makeStore(
            search("One"),
            Quicklink(name: "None", link: "~/Downloads"),
            Quicklink(name: "Two", link: "https://example.com/{argument name=\"A\"}/{argument name=\"B\"}"),
            // Used twice, it is still one input.
            Quicklink(name: "Twice", link: "https://example.com/{argument name=\"A\"}?again={argument name=\"A\"}")
        )
        let candidates = await makeEngine(store, fallbacks: []).fallbackCandidates()
        #expect(candidates.map(\.title) == ["Quicklinks", "Ask"])
        #expect(candidates.map { $0.items.map(\.title) } == [["One", "Twice"], ["Ask AI"]])
    }

    @Test func offersTheChosenCommandsUnderTheQuery() async throws {
        let engine = await makeEngine(makeStore(search("First"), search("Second")), fallbacks: ["Second", "ask:ai", "First"])
        let section = try #require(engine.fallbacks(for: "  swift  "))
        #expect(section.title == "Use “swift” with")
        #expect(section.items.map(\.title) == ["Second", "Ask AI", "First"])
        // The query is the argument, so there is nothing left to ask for.
        #expect(section.items.flatMap(\.arguments).isEmpty)
    }

    @Test func aFallbackRunsWithTheQueryAsItsArgument() async throws {
        let module = AskModule()
        let engine = SearchEngine(
            modules: [module],
            usage: UsageStore(fileURL: nil),
            fallbacks: FallbackStore(fileURL: nil, initial: ["ask:ai"])
        )
        await engine.reloadAll()
        let fallback = try #require(engine.fallbacks(for: "why is the sky blue")?.items.first)
        try await fallback.actions[0].perform(ActionContext(query: " why is the sky blue "))
        #expect(module.asked == [["why is the sky blue"]])
    }

    @Test func offersNothingWithoutAQueryOrAChoice() async {
        let store = makeStore(search("First"))
        #expect(await makeEngine(store, fallbacks: ["First"]).fallbacks(for: " ") == nil)
        #expect(await makeEngine(store, fallbacks: []).fallbacks(for: "swift") == nil)
    }

    @Test func aChoiceThatCannotBeAFallbackIsLeftOut() async {
        let store = makeStore(search("First"), Quicklink(name: "Folder", link: "~/Downloads"))
        let engine = await makeEngine(store, fallbacks: ["Folder", "ask:translate", "gone:command", "First"])
        #expect(engine.chosenFallbacks().map(\.title) == ["First"])
    }

    @Test func aDisabledModuleOffersNoFallbacks() async {
        let engine = await makeEngine(makeStore(search("First")), fallbacks: ["First", "ask:ai"])
        engine.isEnabled = { $0 != "quicklinks" }
        #expect(engine.fallbackCandidates().map(\.title) == ["Ask"])
        #expect(engine.fallbacks(for: "swift")?.items.map(\.title) == ["Ask AI"])
        // The choice is kept for when the module is back.
        engine.isEnabled = { _ in true }
        #expect(engine.fallbacks(for: "swift")?.items.map(\.title) == ["First", "Ask AI"])
    }

    @Test func shortensALongQueryInTheTitle() {
        let title = SearchEngine.fallbackTitle(for: String(repeating: "a", count: 60))
        #expect(title == "Use “\(String(repeating: "a", count: 40))…” with")
    }

    @Test func aCommandAndItsFallbackHaveDifferentIDs() async throws {
        let engine = await makeEngine(makeStore(search("First")), fallbacks: ["First"])
        let candidate = try #require(engine.fallbackCandidates().first?.items.first)
        let fallback = try #require(engine.fallbacks(for: "swift")?.items.first)
        #expect(candidate.id != fallback.id)
    }

    // MARK: - The choice

    @Test func addsAndRemovesAChoice() {
        let store = FallbackStore(fileURL: nil, initial: ["a"])
        store.add("b")
        store.add("a")
        #expect(store.ids == ["a", "b"])
        store.remove("a")
        #expect(store.ids == ["b"])
    }

    @Test func movesAChoicePastTheOnesThatAreAway() {
        let store = FallbackStore(fileURL: nil, initial: ["first", "away", "second", "third"])
        let listed = ["first", "second", "third"]
        store.move("third", by: -2, among: listed)
        // What is not listed keeps its place.
        #expect(store.ids == ["third", "away", "first", "second"])

        store.move("third", by: -1, among: listed)
        store.move("second", by: 1, among: listed)
        #expect(store.ids == ["third", "away", "first", "second"])
    }

    @Test func keepsTheChoiceInItsFile() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FallbackStore(fileURL: file, initial: ["a", "b"])
        store.move("b", by: -1, among: ["a", "b"])
        store.add("c")
        // What it would start with no longer counts once there is a file.
        #expect(FallbackStore(fileURL: file, initial: ["z"]).ids == ["b", "a", "c"])
    }

    // MARK: - Where the choice starts

    @Test func aNewInstallStartsWithTheSearchesItCameWith() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = QuicklinkStore(fileURL: file)
        #expect(store.initialFallbacks == store.quicklinks.prefix(3).map(\.itemID))
        // And the same when read back.
        #expect(QuicklinkStore(fileURL: file).initialFallbacks == store.initialFallbacks)
    }

    @Test func aFileThatSaysWhichQuicklinksAreFallbacksIsTakenAtItsWord() throws {
        let ids = (0..<4).map { _ in UUID() }
        let json = """
        [
          {"id": "\(ids[0])", "name": "DDG", "link": "https://duckduckgo.com/?q={argument name=\\"Query\\"}"},
          {"id": "\(ids[1])", "name": "Mine", "link": "https://example.com/?q={argument name=\\"Query\\"}"},
          {"id": "\(ids[2])", "name": "Off", "link": "https://duckduckgo.com/?q={argument name=\\"Query\\"}", "isFallback": false},
          {"id": "\(ids[3])", "name": "On", "link": "https://example.com/?q={argument name=\\"Query\\"}", "isFallback": true}
        ]
        """
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(json.utf8).write(to: file)

        let store = QuicklinkStore(fileURL: file)
        #expect(store.quicklinks.map(\.name) == ["DDG", "Mine", "Off", "On"])
        // Where it says nothing, the searches Inky came with are fallbacks.
        #expect(store.initialFallbacks == ["quicklink:\(ids[0])", "quicklink:\(ids[3])"])
    }
}
