import Foundation
import Testing
@testable import InkyCore

@Suite struct BrowserTests {
    // MARK: - Web addresses

    @Test(arguments: [
        ("amazon.com", "https://amazon.com"),
        ("  amazon.com ", "https://amazon.com"),
        ("Amazon.COM", "https://Amazon.COM"),
        ("www.example.org", "https://www.example.org"),
        ("github.com/hinkolas/inky", "https://github.com/hinkolas/inky"),
        ("example.com?q=inky#top", "https://example.com?q=inky#top"),
        ("example.com:8080/status", "https://example.com:8080/status"),
        ("docs.example.co.uk", "https://docs.example.co.uk"),
        ("my-site.dev", "https://my-site.dev"),
        // Loose on purpose: these are names of files, and addresses as well.
        ("main.rs", "https://main.rs"),
        ("readme.md", "https://readme.md"),
        ("notes.app", "https://notes.app"),
    ])
    func whatEndsInATopLevelDomainIsAnAddress(input: String, link: String) {
        #expect(WebAddress(input)?.url.absoluteString == link)
    }

    @Test(arguments: [
        ("http://example.com", "http://example.com"),
        ("https://example.com/a?b=c", "https://example.com/a?b=c"),
        ("HTTPS://example.com", "HTTPS://example.com"),
        // Spelled out, it need not end in a top-level domain.
        ("http://intranet/wiki", "http://intranet/wiki"),
        ("http://nas.local:5000", "http://nas.local:5000"),
        ("https://user@example.com/", "https://user@example.com/"),
        ("http://[::1]:8080/", "http://[::1]:8080/"),
    ])
    func anAddressSpelledOutIsOpenedAsItIs(input: String, link: String) {
        #expect(WebAddress(input)?.url.absoluteString == link)
    }

    @Test(arguments: [
        ("localhost", "http://localhost"),
        ("localhost:3000", "http://localhost:3000"),
        ("LocalHost:3000/api/users", "http://LocalHost:3000/api/users"),
        ("192.168.0.1", "http://192.168.0.1"),
        ("127.0.0.1:8080/health", "http://127.0.0.1:8080/health"),
    ])
    func whatIsOnThisMacOrNetworkIsNotServedSecurely(input: String, link: String) {
        #expect(WebAddress(input)?.url.absoluteString == link)
    }

    @Test func aNameInAnotherScriptIsLookedUpByItsAsciiForm() {
        #expect(WebAddress("münchen.de")?.url.absoluteString == "https://xn--mnchen-3ya.de")
        // The top-level domain may be in another script too.
        #expect(WebAddress("例え.みんな")?.url.absoluteString == "https://xn--r8jz45g.xn--q9jyb4c")
        #expect(WebAddress("例え.例え") == nil)
    }

    @Test(arguments: [
        "", " ", "amazon", "safari", "amazon.", ".com", "amazon..com", "amazon.com.", "-a.com", "a-.com",
        // Not a top-level domain.
        "node.js", "package.json", "index.html", "www.example", "nas.local", "a.b",
        // Numbers, and what the calculator is asked.
        "1.5", "3.14", "2 * 4", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.", "10.5.com.",
        // More than an address.
        "amazon.com shoes", "open amazon.com", "amazon.com\tshoes",
        // Mail and other kinds of link.
        "name@example.com", "mailto:name@example.com", "slack://open", "file:///Users", "ftp://example.com",
        "~/Downloads", "/usr/local", "https://", "http:///path", "https:example.com",
        // No port.
        "example.com:", "example.com:abc", "example.com:0", "example.com:65536", "localhost:", "localhost:3000x",
    ])
    func whatIsNoAddressIsNone(input: String) {
        #expect(WebAddress(input) == nil)
    }

    @Test func anAddressLongerThanAnyTypedIsNone() {
        #expect(WebAddress("example.com/" + String(repeating: "a", count: 2000)) != nil)
        #expect(WebAddress("example.com/" + String(repeating: "a", count: 2100)) == nil)
    }

    // MARK: - Top-level domains

    @Test func theListIsReadAsItComes() {
        let domains = TopLevelDomains.parse("# Version 2026111200\nCOM\nDE\r\nXN--P1AI\n\n  rs  \n")
        #expect(domains == ["com", "de", "xn--p1ai", "rs"])
    }

    @Test func theListThatShipsHasTheDomainsThereAre() {
        let domains = TopLevelDomains.all
        #expect(domains.count > 1000)
        for domain in ["com", "org", "net", "de", "io", "dev", "app", "rs", "md", "xn--p1ai"] {
            #expect(domains.contains(domain), "\(domain) is missing")
        }
        #expect(!domains.contains { $0.hasPrefix("#") || $0 != $0.lowercased() })
    }

    // MARK: - The module

    @MainActor
    @Test func anAddressIsOneRowThatOpensIt() async throws {
        var opened: [URL] = []
        let module = BrowserModule { url in
            opened.append(url)
            return true
        }
        let rows = module.instantResults(for: "github.com/hinkolas/inky")
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.id == "browser:open")
        #expect(row.title == "Open in Browser")
        #expect(row.subtitle == "https://github.com/hinkolas/inky")
        #expect(row.kind == "Link")
        #expect(row.actions.map(\.title) == ["Open Link", "Copy Link"])

        try await row.actions[0].perform(ActionContext(query: "github.com/hinkolas/inky"))
        #expect(opened.map(\.absoluteString) == ["https://github.com/hinkolas/inky"])
    }

    @MainActor
    @Test func aQuicklinkToTheAddressCanBeMadeWhereTheAppOffersIt() async throws {
        var links: [String] = []
        let module = BrowserModule { _ in true }
        module.onCreateQuicklink = { links.append($0) }
        let row = try #require(module.instantResults(for: "amazon.com").first)
        #expect(row.actions.map(\.title) == ["Open Link", "Copy Link", "Create Quicklink"])
        #expect(Set(row.actions.map(\.id)).count == row.actions.count)

        // The editor opens in the launcher, which stays.
        let action = row.actions[2]
        guard case .keepOpen = action.behavior else {
            Issue.record("Making a quicklink closes the launcher")
            return
        }
        try await action.perform(ActionContext(query: "amazon.com"))
        #expect(links == ["https://amazon.com"])
    }

    @MainActor
    @Test func anAddressThatCannotBeOpenedSaysSo() async throws {
        let module = BrowserModule { _ in false }
        let row = try #require(module.instantResults(for: "localhost:3000").first)
        await #expect(throws: InkyError.self) {
            try await row.actions[0].perform(ActionContext())
        }
    }

    @MainActor
    @Test func whatIsNoAddressHasNoRow() {
        let module = BrowserModule { _ in true }
        for query in ["safari", "2 * 4", "time in tokyo", "name@example.com", "amazon.com shoes"] {
            #expect(module.instantResults(for: query).isEmpty, "\(query)")
        }
    }

    /// Below what is asked of it, the engine lists the row first: the
    /// address is what was typed, whatever else it resembles.
    @MainActor
    @Test func theEngineListsTheAddressAboveWhatMatches() async {
        let engine = SearchEngine(
            modules: [Named(), BrowserModule { _ in true }],
            usage: UsageStore(fileURL: nil)
        )
        await engine.reloadAll()
        let sections = engine.results(for: "amazon.com")
        #expect(sections.first?.title == "Browser")
        #expect(sections.first?.items.map(\.id) == ["browser:open"])
        #expect(sections.dropFirst().flatMap(\.items).map(\.id) == ["named:amazon"])
        #expect(engine.results(for: "amazon").first?.items.map(\.id) == ["named:amazon"])
    }

    /// A module with one thing to find, named like an address.
    @MainActor
    private final class Named: Module {
        let id = "named"
        let info = ModuleInfo(title: "Named", summary: "", icon: .symbol("link", tint: .gray))
        var onChange: (@MainActor () -> Void)?

        func candidates() async -> [ResultItem] {
            [ResultItem(id: "named:amazon", title: "Amazon.com", icon: info.icon, kind: "Named", actions: [])]
        }
    }
}
