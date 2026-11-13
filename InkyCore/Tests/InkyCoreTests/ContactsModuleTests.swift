import Contacts
import Foundation
import Testing
@testable import InkyCore

private final class StubContacts: ContactsReading, @unchecked Sendable {
    var access: ContactsAccess
    var grantsWhenAsked = true
    var records: [ContactRecord]
    private(set) var reads = 0

    init(access: ContactsAccess = .allowed, _ records: [ContactRecord]) {
        self.access = access
        self.records = records
    }

    func requestAccess() async -> Bool {
        access = grantsWhenAsked ? .allowed : .denied
        return grantsWhenAsked
    }

    func contacts() async throws -> [ContactRecord] {
        reads += 1
        return records
    }

    func picture(of id: String) async -> Data? {
        records.contains { $0.id == id && $0.hasPicture } ? Data("picture of \(id)".utf8) : nil
    }

    func details(of id: String) async -> ContactDetails? {
        records.first { $0.id == id }.map { record in
            ContactDetails(id: id, jobTitle: "Harbor Master", emails: record.emails.map { .init("work", $0) })
        }
    }
}

@MainActor
@Suite struct ContactsModuleTests {
    private let thomas = ContactRecord(
        id: "1:ABPerson", name: "Thomas Becker", nickname: "Tom", organization: "Harbor Office",
        emails: ["tom@becker.example", "thomas@harbor.example"], phones: ["+49 171 555 0118"]
    )

    private func makeEngine(_ reader: StubContacts) async -> (SearchEngine, ContactsModule) {
        let module = ContactsModule(reader: reader)
        let engine = SearchEngine(modules: [module], usage: UsageStore(fileURL: nil))
        await engine.reloadAll()
        return (engine, module)
    }

    @Test func describesAPerson() throws {
        let item = try #require(ContactsModule.item(for: thomas))
        #expect(item.id == "1:ABPerson")
        #expect(item.domain == "people")
        #expect(item.title == "Thomas Becker")
        #expect(item.subtitle == "Harbor Office")
        #expect(item.keywords == ["Tom", "Harbor Office", "tom@becker.example", "thomas@harbor.example"])
        #expect(item.kind == "Contact")
        #expect(item.info == [
            "name": "Thomas Becker", "organization": "Harbor Office",
            "email": "tom@becker.example", "phone": "+49 171 555 0118",
        ])
        #expect(ContactsModule.groups(of: item).isEmpty)
    }

    @Test func remembersTheGroupsAContactIsIn() throws {
        var record = thomas
        record.groups = ["Harbor", "Sailing Club"]
        let item = try #require(ContactsModule.item(for: record))
        #expect(ContactsModule.groups(of: item) == ["Harbor", "Sailing Club"])
    }

    @Test func aContactWithAPictureSaysWhereItIs() async throws {
        let plain = try #require(ContactsModule.item(for: thomas))
        #expect(plain.icon == .symbol("person.fill", tint: .orange))

        var record = thomas
        record.hasPicture = true
        let pictured = try #require(ContactsModule.item(for: record))
        // Not the picture itself: who has it, and what stands in for it.
        #expect(pictured.icon == .picture(source: "contacts", id: "1:ABPerson", fallback: .symbol("person.fill", tint: .orange)))

        let reader = StubContacts([record, ContactRecord(id: "2", name: "Mara Okafor")])
        let (engine, _) = await makeEngine(reader)
        let found = try #require(engine.results(for: "thomas").first?.items.first)
        #expect(found.icon == pictured.icon)
        #expect(await engine.picture(of: "1:ABPerson", from: "contacts") == Data("picture of 1:ABPerson".utf8))
        #expect(await engine.picture(of: "2", from: "contacts") == nil)
        #expect(await engine.picture(of: "1:ABPerson", from: "nobody") == nil)

        // Not once Inky may not read the contacts, or the module is off.
        reader.access = .denied
        #expect(await engine.picture(of: "1:ABPerson", from: "contacts") == nil)
        reader.access = .allowed
        engine.isEnabled = { _ in false }
        #expect(await engine.picture(of: "1:ABPerson", from: "contacts") == nil)
    }

    @Test func hasACommandThatShowsThemAll() async throws {
        let (engine, module) = await makeEngine(StubContacts([thomas]))
        var opened: [String] = []
        module.onOpen = { opened.append($0) }

        let command = try #require(engine.results(for: "search contacts").first?.items.first)
        #expect(command.id == ContactsModule.searchID)
        #expect(engine.isCommand(command))
        // Who to look for can be typed along, or left out.
        #expect(command.arguments.map(\.isRequired) == [false])
        #expect(command.canBeFallback)
        try await command.actions[0].perform(ActionContext(arguments: ["thomas"]))
        try await command.actions[0].perform(ActionContext())
        #expect(opened == ["thomas", ""])
    }

    @Test func readsMoreAboutAContactOnlyWhileItMay() async {
        let reader = StubContacts([thomas])
        let (_, module) = await makeEngine(reader)
        #expect(await module.details(of: "1:ABPerson")?.jobTitle == "Harbor Master")
        #expect(await module.details(of: "nobody") == nil)

        reader.access = .denied
        #expect(await module.details(of: "1:ABPerson") == nil)
    }

    @Test func aContactListedElsewhereIsTheResultItIsInTheSearch() async throws {
        let (engine, _) = await makeEngine(StubContacts([thomas]))
        let item = try #require(engine.index.items(of: "contacts").first)
        let listed = try #require(engine.result(for: item, from: "contacts"))
        let found = try #require(engine.results(for: "thomas").first?.items.first)
        #expect(listed.id == found.id)
        #expect(listed.actions.map(\.title) == found.actions.map(\.title))

        engine.isEnabled = { _ in false }
        #expect(engine.result(for: item, from: "contacts") == nil)
    }

    @Test func callsAContactByWhatThereIs() throws {
        let company = try #require(ContactsModule.item(for: ContactRecord(
            id: "2", name: "", organization: "Crane Works", isOrganization: true, emails: ["office@crane.example"]
        )))
        #expect(company.title == "Crane Works")
        #expect(company.subtitle == "office@crane.example")
        #expect(company.domain == "organizations")
        #expect(company.keywords == ["office@crane.example"])

        let address = try #require(ContactsModule.item(for: ContactRecord(id: "3", name: " ", emails: ["a@b.example"])))
        #expect(address.title == "a@b.example")
        #expect(address.subtitle == nil)

        #expect(ContactsModule.item(for: ContactRecord(id: "4", name: "")) == nil)
    }

    @Test func findsContactsByNameNicknameCompanyAndAddress() async {
        let (engine, _) = await makeEngine(StubContacts([thomas, ContactRecord(id: "2", name: "Mara Okafor")]))
        for query in ["thomas", "becker", "tom", "harbor", "tom@becker"] {
            #expect(engine.results(for: query).flatMap(\.items).map(\.id) == ["contacts:1:ABPerson"], "\(query)")
        }
        // Its command is found by its own name, not among the people.
        #expect(engine.results(for: "contacts").flatMap(\.items).map(\.id) == [ContactsModule.searchID])
        // Not by the digits of a phone number, which are typed for sums.
        #expect(engine.results(for: "171").isEmpty)
    }

    @Test func offersWhatAContactCanBeReachedBy() async throws {
        let (engine, _) = await makeEngine(StubContacts([thomas, ContactRecord(id: "2", name: "Mara Okafor")]))
        let found = try #require(engine.results(for: "thomas").first?.items.first)
        #expect(found.actions.map(\.title) == [
            "Open in Contacts", "Send Email", "Send Message", "Call",
            "Copy Email Address", "Copy Phone Number",
        ])
        let mara = try #require(engine.results(for: "mara").first?.items.first)
        #expect(mara.actions.map(\.title) == ["Open in Contacts"])
    }

    @Test func readsNothingBeforeItMay() async {
        let reader = StubContacts(access: .notAsked, [thomas])
        let (engine, module) = await makeEngine(reader)
        #expect(reader.reads == 0)
        #expect(engine.results(for: "thomas").isEmpty)

        #expect(await module.requestAccess())
        #expect(module.access == .allowed)
        #expect(reader.reads == 1)
        #expect(engine.results(for: "thomas").flatMap(\.items).count == 1)
    }

    @Test func findsNothingWhenRefused() async {
        let reader = StubContacts(access: .notAsked, [thomas])
        reader.grantsWhenAsked = false
        let (engine, module) = await makeEngine(reader)
        #expect(await module.requestAccess() == false)
        #expect(reader.reads == 0)
        #expect(engine.results(for: "thomas").isEmpty)
    }

    @Test func forgetsTheContactsOnceItMayNotReadThem() async {
        let reader = StubContacts([thomas])
        let (engine, module) = await makeEngine(reader)
        #expect(engine.index.count(of: "contacts") == 1)

        reader.access = .denied
        module.refreshAccess()
        for _ in 0..<50 where engine.index.count(of: "contacts") > 0 { await Task.yield() }
        #expect(engine.index.count(of: "contacts") == 0)
    }

    @Test func readsThemAgainWhenTheyChange() async {
        let reader = StubContacts([thomas])
        let (engine, _) = await makeEngine(reader)
        reader.records.append(ContactRecord(id: "2", name: "Mara Okafor"))
        NotificationCenter.default.post(name: .CNContactStoreDidChange, object: nil)
        // Changes come in bursts, and are waited out.
        for _ in 0..<40 where engine.index.count(of: "contacts") < 2 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(engine.index.count(of: "contacts") == 2)
    }

    @Test func keepsNothingOnDisk() {
        #expect(ContactsModule(reader: StubContacts([])).indexStorage == .memory)
    }
}
