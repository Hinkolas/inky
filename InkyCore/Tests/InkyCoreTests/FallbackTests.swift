import Foundation
import Testing
@testable import InkyCore

@MainActor
@Suite struct FallbackTests {
    private func search(_ name: String, isFallback: Bool = true) -> Quicklink {
        Quicklink(name: name, link: "https://example.com/\(name)?q={argument name=\"Query\"}", isFallback: isFallback)
    }

    private func makeStore(_ quicklinks: Quicklink...) -> QuicklinkStore {
        let store = QuicklinkStore(fileURL: nil)
        quicklinks.forEach(store.save)
        return store
    }

    private func makeEngine(_ store: QuicklinkStore) -> SearchEngine {
        SearchEngine(modules: [QuicklinkModule(store: store)], usage: UsageStore(fileURL: nil))
    }

    @Test func onlyQuicklinksWithOneArgumentCanBeFallbacks() {
        #expect(search("One").canBeFallback)
        #expect(!Quicklink(name: "None", link: "~/Downloads").canBeFallback)
        #expect(!Quicklink(name: "Two", link: "https://example.com/{argument name=\"A\"}/{argument name=\"B\"}").canBeFallback)
        // Used twice, it is still one input.
        #expect(Quicklink(name: "Twice", link: "https://example.com/{argument name=\"A\"}?again={argument name=\"A\"}").canBeFallback)
    }

    @Test func listsEnabledFallbacksInOrder() {
        let store = makeStore(
            search("First"),
            Quicklink(name: "Folder", link: "~/Downloads", isFallback: true),
            search("Off", isFallback: false),
            search("Second")
        )
        #expect(store.fallbacks.map(\.name) == ["First", "Second"])
    }

    @Test func offersFallbacksUnderTheQuery() throws {
        let engine = makeEngine(makeStore(search("First"), search("Second")))
        let section = try #require(engine.fallbacks(for: "  swift  "))
        #expect(section.title == "Use “swift” with")
        #expect(section.items.map(\.title) == ["First", "Second"])
        // The query is the argument, so there is nothing left to ask for.
        #expect(section.items.flatMap(\.arguments).isEmpty)
    }

    @Test func offersNothingWithoutAQueryOrFallbacks() {
        #expect(makeEngine(makeStore(search("First"))).fallbacks(for: " ") == nil)
        #expect(makeEngine(makeStore(search("Off", isFallback: false))).fallbacks(for: "swift") == nil)
    }

    @Test func aDisabledModuleOffersNoFallbacks() {
        let engine = makeEngine(makeStore(search("First")))
        engine.isEnabled = { _ in false }
        #expect(engine.fallbacks(for: "swift") == nil)
    }

    @Test func shortensALongQueryInTheTitle() {
        let title = SearchEngine.fallbackTitle(for: String(repeating: "a", count: 60))
        #expect(title == "Use “\(String(repeating: "a", count: 40))…” with")
    }

    @Test func fallbackAndCandidateOfOneQuicklinkHaveDifferentIDs() async throws {
        let store = makeStore(search("First"))
        let module = QuicklinkModule(store: store)
        let candidate = try #require(await module.candidates().first)
        let fallback = try #require(module.fallbackResults(for: "swift").first)
        #expect(candidate.id != fallback.id)
    }

    @Test func turnsAFallbackOnAndOff() {
        let store = makeStore(search("First"), search("Second"))
        store.setFallback(store.quicklinks[0].id, false)
        #expect(store.fallbacks.map(\.name) == ["Second"])
        store.setFallback(store.quicklinks[0].id, true)
        #expect(store.fallbacks.map(\.name) == ["First", "Second"])
    }

    @Test func movesACandidatePastTheQuicklinksInBetween() {
        let store = makeStore(
            search("First"),
            Quicklink(name: "Folder", link: "~/Downloads"),
            search("Second"),
            search("Third")
        )
        store.moveFallbackCandidate(store.quicklinks[3].id, by: -2)
        #expect(store.fallbacks.map(\.name) == ["Third", "First", "Second"])
        // What cannot be a fallback keeps its place.
        #expect(store.quicklinks.map(\.name) == ["Third", "Folder", "First", "Second"])

        store.moveFallbackCandidate(store.quicklinks[0].id, by: -1)
        store.moveFallbackCandidate(store.quicklinks[3].id, by: 1)
        #expect(store.fallbacks.map(\.name) == ["Third", "First", "Second"])
    }

    @Test func aFileFromBeforeFallbacksTreatsTheStarterSearchesAsFallbacks() throws {
        let json = """
        [
          {"id": "\(UUID().uuidString)", "name": "DDG", "link": "https://duckduckgo.com/?q={argument name=\\"Query\\"}"},
          {"id": "\(UUID().uuidString)", "name": "Mine", "link": "https://example.com/?q={argument name=\\"Query\\"}"},
          {"id": "\(UUID().uuidString)", "name": "Off", "link": "https://duckduckgo.com/?q={argument name=\\"Query\\"}", "isFallback": false}
        ]
        """
        let quicklinks = try JSONDecoder().decode([Quicklink].self, from: Data(json.utf8))
        #expect(quicklinks.map(\.isFallback) == [true, false, false])
    }

    @Test func aNewInstallComesWithFallbacks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("inky-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(QuicklinkStore(fileURL: file).fallbacks.count == 3)
        // And they are still fallbacks when read back.
        #expect(QuicklinkStore(fileURL: file).fallbacks.count == 3)
    }
}
