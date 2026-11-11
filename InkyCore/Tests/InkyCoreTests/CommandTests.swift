import Foundation
import Testing
@testable import InkyCore

@MainActor
private final class ShelfModule: Module {
    let id: String
    let info: ModuleInfo
    var onChange: (@MainActor () -> Void)?
    var titles: [String]
    /// Which of them ask for one argument, and so can be fallbacks.
    var asking: Set<String> = []

    init(id: String, titles: [String]) {
        self.id = id
        self.titles = titles
        info = ModuleInfo(title: id.capitalized, summary: "", icon: .symbol("star", tint: .gray))
    }

    func candidates() async -> [ResultItem] {
        titles.map { title in
            ResultItem(
                id: "\(id):\(title)",
                title: title,
                icon: info.icon,
                kind: "Stub",
                arguments: asking.contains(title) ? [Argument(name: "Query")] : [],
                actions: []
            )
        }
    }
}

@MainActor
@Suite struct CommandTests {
    private let space = KeyCombo(keyCode: 49, modifiers: 1 << 19)
    private let v = KeyCombo(keyCode: 9, modifiers: 1 << 20)

    private func titles(_ sections: [ResultSection]) -> [String] {
        sections.flatMap(\.items).map(\.title)
    }

    private func makeEngine(_ modules: ShelfModule..., fallbacks: [String] = []) async -> SearchEngine {
        let engine = SearchEngine(
            modules: modules,
            usage: UsageStore(fileURL: nil),
            fallbacks: FallbackStore(fileURL: nil, initial: fallbacks)
        )
        await engine.reloadAll()
        return engine
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inky-\(UUID().uuidString).json")
    }

    // MARK: - Switching a command off

    @Test func aDisabledCommandIsNotFound() async {
        let engine = await makeEngine(ShelfModule(id: "apps", titles: ["Safari", "Disk Safety"]))
        engine.commandStore.setEnabled("apps:Safari", false)
        #expect(titles(engine.results(for: "saf")) == ["Disk Safety"])

        engine.commandStore.setEnabled("apps:Safari", true)
        #expect(titles(engine.results(for: "saf")) == ["Safari", "Disk Safety"])
    }

    @Test func aDisabledCommandIsNotSuggested() async throws {
        let engine = await makeEngine(ShelfModule(id: "apps", titles: ["Mail", "Safari"]))
        let safari = try #require(engine.results(for: "safari").first?.items.first)
        engine.recordUse(of: safari, query: "safari")
        #expect(engine.results(for: "").map(\.title) == ["Suggestions", "Apps"])

        engine.commandStore.setEnabled("apps:Safari", false)
        #expect(engine.results(for: "").map(\.title) == ["Apps"])
        #expect(titles(engine.results(for: "")) == ["Mail"])
    }

    @Test func aDisabledCommandIsNoFallback() async {
        let module = ShelfModule(id: "web", titles: ["Search", "Translate"])
        module.asking = ["Search", "Translate"]
        let engine = await makeEngine(module, fallbacks: ["web:Search", "web:Translate"])
        engine.commandStore.setEnabled("web:Search", false)
        #expect(engine.fallbackCandidates().flatMap(\.items).map(\.title) == ["Translate"])
        #expect(engine.fallbacks(for: "swift")?.items.map(\.title) == ["Translate"])

        // The choice is kept for when the command is back.
        engine.commandStore.setEnabled("web:Search", true)
        #expect(engine.fallbacks(for: "swift")?.items.map(\.title) == ["Search", "Translate"])
    }

    @Test func listsTheCommandsOfAModuleByNameWhateverTheirState() async {
        let engine = await makeEngine(
            ShelfModule(id: "apps", titles: ["Safari", "Mail", "Notes"]),
            ShelfModule(id: "system", titles: ["Sleep"])
        )
        engine.commandStore.setEnabled("apps:Mail", false)
        #expect(engine.commands(in: "apps").map(\.title) == ["Mail", "Notes", "Safari"])
        #expect(engine.commands(in: "nothing").isEmpty)
    }

    @Test func onlyWhatAModuleListsIsACommand() async throws {
        let engine = await makeEngine(ShelfModule(id: "apps", titles: ["Safari"]))
        let safari = try #require(engine.results(for: "safari").first?.items.first)
        #expect(engine.isCommand(safari))
        let answer = ResultItem(id: "calculator:1+1", title: "2", icon: .symbol("equal", tint: .gray), kind: "Calculation", actions: [])
        #expect(!engine.isCommand(answer))
    }

    // MARK: - Running a command

    @Test func aCommandCanBeRunWhileItAndItsModuleAreOn() async {
        let engine = await makeEngine(ShelfModule(id: "apps", titles: ["Safari"]))
        #expect(engine.command(withID: "apps:Safari")?.title == "Safari")
        #expect(engine.command(withID: "apps:Gone") == nil)

        engine.commandStore.setEnabled("apps:Safari", false)
        #expect(engine.command(withID: "apps:Safari") == nil)
        engine.commandStore.setEnabled("apps:Safari", true)

        engine.isEnabled = { $0 != "apps" }
        #expect(engine.command(withID: "apps:Safari") == nil)
    }

    // MARK: - The store

    @Test func givesAndTakesAHotkey() {
        let store = CommandStore(fileURL: nil)
        store.setHotkey(v, for: "clipboard:history")
        #expect(store.hotkey(for: "clipboard:history") == v)
        #expect(store.command(with: v) == "clipboard:history")
        #expect(store.command(with: space) == nil)

        store.setHotkey(nil, for: "clipboard:history")
        #expect(store.hotkeys.isEmpty)
    }

    @Test func saysWhenSomethingChanged() {
        let store = CommandStore(fileURL: nil)
        var changes = 0
        store.onChange = { changes += 1 }
        store.setEnabled("a", false)
        store.setHotkey(v, for: "a")
        #expect(changes == 2)
        // Nothing new is nothing to say.
        store.setEnabled("a", false)
        store.setHotkey(v, for: "a")
        store.forget("b")
        #expect(changes == 2)
    }

    @Test func forgetsACommandThatIsGone() {
        let store = CommandStore(fileURL: nil)
        store.setEnabled("a", false)
        store.setHotkey(v, for: "a")
        store.forget("a")
        #expect(store.isEnabled("a"))
        #expect(store.hotkey(for: "a") == nil)
    }

    @Test func keepsWhatWasDecidedInAFile() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = CommandStore(fileURL: file)
        store.setEnabled("app:/Applications/Chess.app", false)
        store.setHotkey(v, for: "clipboard:history")

        let reopened = CommandStore(fileURL: file)
        #expect(reopened.disabled == ["app:/Applications/Chess.app"])
        #expect(reopened.hotkeys == ["clipboard:history": v])
    }

    @Test func startsWithTheGivenHotkeysOnlyWhereThereIsNoFile() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let first = CommandStore(fileURL: file, initialHotkeys: ["clipboard:history": v])
        #expect(first.hotkeys == ["clipboard:history": v])
        first.setHotkey(nil, for: "clipboard:history")

        // Taken away, it stays away.
        let second = CommandStore(fileURL: file, initialHotkeys: ["clipboard:history": v])
        #expect(second.hotkeys.isEmpty)
    }

    @Test func aFileThatCannotBeReadDecidesNothing() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)

        let store = CommandStore(fileURL: file, initialHotkeys: ["clipboard:history": v])
        #expect(store.disabled.isEmpty)
        #expect(store.hotkeys.isEmpty)
    }
}
