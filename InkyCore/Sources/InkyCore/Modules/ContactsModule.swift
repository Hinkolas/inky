import AppKit
import Contacts

/// What Inky reads of one of the user's contacts.
public struct ContactRecord: Sendable, Hashable {
    public var id: String
    /// The whole name, as macOS writes it. Empty for a contact without one.
    public var name: String
    public var nickname: String
    public var organization: String
    /// Whether the contact is a company, not a person.
    public var isOrganization: Bool
    public var emails: [String]
    public var phones: [String]

    public init(
        id: String,
        name: String,
        nickname: String = "",
        organization: String = "",
        isOrganization: Bool = false,
        emails: [String] = [],
        phones: [String] = []
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.organization = organization
        self.isOrganization = isOrganization
        self.emails = emails
        self.phones = phones
    }
}

/// Whether macOS lets Inky read the contacts.
public enum ContactsAccess: Sendable {
    /// The user was never asked.
    case notAsked
    case allowed
    case denied
}

/// Where contacts come from. The app reads the user's; tests and runs with
/// data of their own read made-up ones.
public protocol ContactsReading: Sendable {
    var access: ContactsAccess { get }
    /// Has macOS ask the user. Returns whether Inky may read the contacts.
    func requestAccess() async -> Bool
    /// Every contact. Not called on the main thread.
    func contacts() async throws -> [ContactRecord]
}

/// The contacts of the Mac.
public final class SystemContacts: ContactsReading, @unchecked Sendable {
    /// Kept, because changes are only announced while there is a store.
    private let store = CNContactStore()

    public init() {}

    public var access: ContactsAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .notAsked
        case .authorized: .allowed
        default: .denied
        }
    }

    public func requestAccess() async -> Bool {
        (try? await store.requestAccess(for: .contacts)) ?? false
    }

    public func contacts() async throws -> [ContactRecord] {
        let keys: [any CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactTypeKey as NSString,
            CNContactNicknameKey as NSString,
            CNContactOrganizationNameKey as NSString,
            CNContactEmailAddressesKey as NSString,
            CNContactPhoneNumbersKey as NSString,
        ]
        var records: [ContactRecord] = []
        try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            records.append(ContactRecord(
                id: contact.identifier,
                name: CNContactFormatter.string(from: contact, style: .fullName) ?? "",
                nickname: contact.nickname,
                organization: contact.organizationName,
                isOrganization: contact.contactType == .organization,
                emails: contact.emailAddresses.map { $0.value as String },
                phones: contact.phoneNumbers.map(\.value.stringValue)
            ))
        }
        return records
    }
}

/// The people and companies in the user's contacts, found by name in the
/// search.
///
/// They are items of the search index, not commands. They are read into
/// memory and never written to disk: macOS guards the contacts, and a copy
/// among Inky's files would be there for any application to read.
@MainActor
public final class ContactsModule: SearchableSource {
    public static let icon = Icon.symbol("person.crop.circle.fill", tint: .orange)

    public let id = "contacts"
    public let info = ModuleInfo(
        title: "Contacts",
        summary: "Find people in your contacts by name, and write to or call them. Asks before it reads them.",
        icon: ContactsModule.icon
    )
    public var onChange: (@MainActor () -> Void)?

    public var index: SourceIndex?
    public let indexStorage = SearchIndex.Storage.memory
    public let resultLimit = 4

    private let reader: any ContactsReading
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    /// The access the contacts were last read with.
    private var readAccess: ContactsAccess?

    public init(reader: any ContactsReading = SystemContacts()) {
        self.reader = reader
        // Posted on any thread, and several times for one change.
        observer = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.contactsDidChange() }
        }
    }

    public var access: ContactsAccess { reader.access }

    /// Has macOS ask whether Inky may read the contacts, and reads them if
    /// it may. Call it from a window of Inky's own: that is where macOS
    /// shows the question.
    @discardableResult
    public func requestAccess() async -> Bool {
        let granted = await reader.requestAccess()
        await reindex()
        return granted
    }

    /// Reads the contacts again if what Inky may do has changed, as after
    /// the user allowed or refused it in System Settings.
    public func refreshAccess() {
        guard index?.isOpen == true, reader.access != readAccess else { return }
        Task { await reindex() }
    }

    private func contactsDidChange() {
        guard index?.isOpen == true else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.reindex()
        }
    }

    public func reindex() async {
        let access = reader.access
        readAccess = access
        guard access == .allowed, index?.isOpen == true else {
            index?.deleteAll()
            return
        }
        guard let records = try? await reader.contacts() else { return }
        index?.replaceAll(with: records.compactMap(Self.item))
    }

    /// A contact as it is found: by its name, and by a nickname, a company
    /// or an email address. Nil for one with nothing to call it by.
    static func item(for contact: ContactRecord) -> SearchableItem? {
        let name = contact.name.trimmingCharacters(in: .whitespaces)
        let organization = contact.organization.trimmingCharacters(in: .whitespaces)
        let known = [name, organization] + contact.emails + contact.phones
        guard let title = known.first(where: { !$0.isEmpty }) else { return nil }
        // What tells the contact from another of the same name.
        let subtitle = ([organization] + contact.emails + contact.phones).first { !$0.isEmpty && $0 != title }

        var info = ["name": title]
        if let email = contact.emails.first { info["email"] = email }
        if let phone = contact.phones.first { info["phone"] = phone }
        return SearchableItem(
            id: contact.id,
            domain: contact.isOrganization ? "organizations" : "people",
            title: title,
            subtitle: subtitle,
            // Not the phone numbers: digits that are typed are mostly sums,
            // and would find numbers that only hold them in that order.
            keywords: ([contact.nickname, organization] + contact.emails).filter { !$0.isEmpty && $0 != title },
            icon: contact.isOrganization ? .symbol("building.2.fill", tint: .orange) : .symbol("person.fill", tint: .orange),
            kind: "Contact",
            info: info
        )
    }

    public func actions(for item: SearchableItem) -> [Action] {
        var actions = [
            Action("Open in Contacts", symbol: "person.crop.circle") { _ in
                // The identifier has a colon in it, which a link would
                // take for the start of a port number.
                let id = item.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? item.id
                try Self.open("addressbook://\(id)")
            },
        ]
        if let email = item.info["email"] {
            actions.append(Action("Send Email", symbol: "envelope") { _ in
                let address = email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? email
                try Self.open("mailto:\(address)")
            })
        }
        if let phone = item.info["phone"] {
            let number = phone.filter { $0.isNumber || $0 == "+" }
            actions.append(Action("Send Message", symbol: "message", shortcut: KeyShortcut("m")) { _ in
                try Self.open("sms:\(number)")
            })
            actions.append(Action("Call", symbol: "phone", shortcut: KeyShortcut("p")) { _ in
                try Self.open("tel:\(number)")
            })
        }
        if let email = item.info["email"] {
            actions.append(.copy(email, title: "Copy Email Address", shortcut: KeyShortcut("c", [.command, .shift])))
        }
        if let phone = item.info["phone"] {
            actions.append(.copy(phone, title: "Copy Phone Number", shortcut: KeyShortcut("c", [.command, .option])))
        }
        if let name = item.info["name"] {
            actions.append(.copy(name, title: "Copy Name"))
        }
        return actions
    }

    private static func open(_ link: String) throws {
        guard let url = URL(string: link), NSWorkspace.shared.open(url) else {
            throw InkyError("Could not open \(link)")
        }
    }
}
