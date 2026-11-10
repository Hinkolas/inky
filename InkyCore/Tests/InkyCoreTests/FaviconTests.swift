import Foundation
import Testing
@testable import InkyCore

@MainActor
@Suite struct FaviconTests {
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    )!

    /// Answers by host, and remembers what it was asked.
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: (Data, Int)?] = [:]
        private var asked: [URL] = []

        var requests: [String] {
            lock.withLock { asked.map(\.absoluteString) }
        }

        /// Nil makes the request fail.
        func answer(_ host: String, _ answer: (Data, Int)?) {
            lock.withLock { answers[host] = answer }
        }

        func fetch(_ url: URL) throws -> (data: Data, status: Int) {
            let host = url.deletingPathExtension().lastPathComponent
            let answer = lock.withLock {
                asked.append(url)
                return answers[host] ?? (Data(), 404)
            }
            guard let answer else { throw URLError(.notConnectedToInternet) }
            return answer
        }
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("favicons-\(UUID().uuidString)")
    }

    private func makeStore(_ source: Source, directory: URL? = nil, using: FaviconSource = .duckDuckGo) -> FaviconStore {
        FaviconStore(directory: directory ?? makeDirectory(), source: using) { try source.fetch($0) }
    }

    /// Lets the store's fetches run until `condition` holds.
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - Hosts

    @Test func findsTheHostOfAWebsite() {
        #expect(Favicon.host(of: "https://github.com/search?q={argument name=\"Query\"}") == "github.com")
        #expect(Favicon.host(of: "  http://EN.Wikipedia.org  ") == "en.wikipedia.org")
        #expect(Favicon.host(of: "example.org/page") == "example.org")
        #expect(Favicon.host(of: "https://user:secret@news.example.org:8443/") == "news.example.org")
        #expect(Favicon.host(of: "https://example.org.") == "example.org")
    }

    @Test func aLinkThatIsNotAWebsiteHasNoHost() {
        #expect(Favicon.host(of: "~/Downloads") == nil)
        #expect(Favicon.host(of: "/Applications") == nil)
        #expect(Favicon.host(of: "obsidian://open?vault=Notes") == nil)
        #expect(Favicon.host(of: "mailto:someone@example.org") == nil)
        #expect(Favicon.host(of: "") == nil)
    }

    @Test func aHostThatIsStillAPlaceholderIsNotOne() {
        #expect(Favicon.host(of: "https://{argument name=\"Team\"}.example.org") == nil)
        #expect(Favicon.host(of: "https://team{argument}.example.org") == nil)
        #expect(Favicon.host(of: "{clipboard}") == nil)
    }

    @Test func hostsOnTheLocalNetworkAreKeptToThemselves() {
        for link in [
            "http://localhost:3000", "http://nas", "http://printer.local", "https://wiki.internal/home",
            "http://192.168.1.1/admin", "http://127.0.0.1:8080", "http://[::1]:8080", "https://router.home.arpa",
        ] {
            #expect(Favicon.host(of: link) == nil, "\(link)")
        }
    }

    @Test func quicklinksToWebsitesAskForTheirIcon() {
        let tile = Icon.symbol("link", tint: .purple)
        #expect(QuicklinkProvider.icon(for: LinkTemplate("https://github.com/{argument}")) == .favicon(host: "github.com", fallback: tile))
        #expect(QuicklinkProvider.icon(for: LinkTemplate("http://localhost:3000")) == tile)
        #expect(QuicklinkProvider.icon(for: LinkTemplate("obsidian://open")) == tile)
    }

    // MARK: - Store

    @Test func fetchesAnIconOnceAndKeepsIt() async throws {
        let source = Source()
        source.answer("github.com", (Self.png, 200))
        let directory = makeDirectory()
        let store = makeStore(source, directory: directory)

        #expect(store.icon(for: "github.com") == nil)
        store.load("github.com")
        store.load("github.com")
        await wait { store.icon(for: "github.com") != nil }

        let icon = try #require(store.icon(for: "github.com"))
        #expect(try Data(contentsOf: icon.url) == Self.png)
        #expect(source.requests == ["https://icons.duckduckgo.com/ip3/github.com.ico"])
        #expect(store.iconCount == 1)

        // Another launch finds it on disk and does not ask again.
        let relaunched = makeStore(source, directory: directory)
        #expect(relaunched.icon(for: "github.com") != nil)
        relaunched.load("github.com")
        await Task.yield()
        #expect(source.requests.count == 1)
    }

    @Test func remembersThatAWebsiteHasNoIcon() async {
        let source = Source()
        // What the source sends with a 404 is a placeholder, not the icon.
        source.answer("nothing.example.org", (Self.png, 404))
        source.answer("broken.example.org", (Data("<html>".utf8), 200))
        let store = makeStore(source)

        store.load("nothing.example.org")
        store.load("broken.example.org")
        await wait { source.requests.count == 2 }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(store.icon(for: "nothing.example.org") == nil)
        #expect(store.icon(for: "broken.example.org") == nil)
        store.load("nothing.example.org")
        store.load("broken.example.org")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(source.requests.count == 2)
    }

    @Test func asksAgainOnceAnAnswerIsOld() async {
        let source = Source()
        source.answer("github.com", (Self.png, 200))
        let store = makeStore(source)
        store.load("github.com")
        await wait { store.icon(for: "github.com") != nil }

        store.load("github.com", now: .now.addingTimeInterval(FaviconStore.iconLifetime - 60))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(source.requests.count == 1)

        store.load("github.com", now: .now.addingTimeInterval(FaviconStore.iconLifetime + 60))
        await wait { source.requests.count == 2 }
        #expect(source.requests.count == 2)
        // The old icon stayed in use meanwhile.
        #expect(store.icon(for: "github.com") != nil)
    }

    @Test func aFailedRequestKeepsWhatWasThere() async throws {
        let source = Source()
        source.answer("github.com", (Self.png, 200))
        let store = makeStore(source)
        store.load("github.com")
        await wait { store.icon(for: "github.com") != nil }
        let before = try #require(store.icon(for: "github.com"))

        source.answer("github.com", nil)
        store.refreshAll()
        await wait { store.refresh?.isRunning == false }

        #expect(store.refresh == FaviconStore.Refresh(total: 1, completed: 1, failed: 1))
        #expect(store.icon(for: "github.com") == before)
    }

    @Test func aWebsiteThatGaveNoAnswerIsLeftAloneForAWhile() async {
        let source = Source()
        source.answer("github.com", nil)
        let store = makeStore(source)

        store.load("github.com")
        await wait { source.requests.count == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        store.load("github.com")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(source.requests.count == 1)

        store.load("github.com", now: .now.addingTimeInterval(FaviconStore.retryDelay + 60))
        await wait { source.requests.count == 2 }
        #expect(source.requests.count == 2)
    }

    @Test func refreshesWhatIsKeptAndWhatIsAskedFor() async {
        let source = Source()
        for host in ["a.example.org", "b.example.org", "c.example.org"] {
            source.answer(host, (Self.png, 200))
        }
        source.answer("d.example.org", (Data(), 500))
        let store = makeStore(source)
        store.load("a.example.org")
        await wait { store.icon(for: "a.example.org") != nil }

        store.refreshAll(including: ["b.example.org", "c.example.org", "d.example.org", "b.example.org"])
        #expect(store.refresh?.isRunning == true)
        // A second refresh does not start while the first one runs.
        store.refreshAll(including: ["e.example.org"])
        await wait { store.refresh?.isRunning == false }

        #expect(store.refresh == FaviconStore.Refresh(total: 4, completed: 4, failed: 1))
        #expect(store.iconCount == 3)
        #expect(source.requests.count == 5)
    }

    @Test func withoutASourceNothingIsAskedOrShown() async {
        let source = Source()
        source.answer("github.com", (Self.png, 200))
        let store = makeStore(source)
        store.load("github.com")
        await wait { store.icon(for: "github.com") != nil }

        store.source = .off
        #expect(store.icon(for: "github.com") == nil)
        store.load("gitlab.com")
        store.refreshAll(including: ["gitlab.com"])
        try? await Task.sleep(for: .milliseconds(20))
        #expect(source.requests.count == 1)
        #expect(store.refresh == nil)

        // Turned on again, what was kept is back without a request.
        store.source = .duckDuckGo
        #expect(store.icon(for: "github.com") != nil)
        #expect(source.requests.count == 1)
    }
}
