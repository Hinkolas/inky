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
    /// The names of the groups the contact is in.
    public var groups: [String]

    public init(
        id: String,
        name: String,
        nickname: String = "",
        organization: String = "",
        isOrganization: Bool = false,
        emails: [String] = [],
        phones: [String] = [],
        groups: [String] = []
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.organization = organization
        self.isOrganization = isOrganization
        self.emails = emails
        self.phones = phones
        self.groups = groups
    }
}

/// What is read of one contact to show it: more than it is found by, and
/// read only for the contact that is looked at.
public struct ContactDetails: Sendable, Hashable {
    /// A value with what it is called: "work", and an address.
    public struct Entry: Sendable, Hashable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public var id: String
    public var jobTitle: String
    public var department: String
    public var phones: [Entry]
    public var emails: [Entry]
    /// Each on one line.
    public var addresses: [Entry]
    public var links: [Entry]
    /// With or without the year.
    public var birthday: DateComponents?
    /// The contact's picture, small, as an image file's data.
    public var picture: Data?

    public init(
        id: String,
        jobTitle: String = "",
        department: String = "",
        phones: [Entry] = [],
        emails: [Entry] = [],
        addresses: [Entry] = [],
        links: [Entry] = [],
        birthday: DateComponents? = nil,
        picture: Data? = nil
    ) {
        self.id = id
        self.jobTitle = jobTitle
        self.department = department
        self.phones = phones
        self.emails = emails
        self.addresses = addresses
        self.links = links
        self.birthday = birthday
        self.picture = picture
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
    /// More about one contact, or nil if it is not there any longer. Not
    /// called on the main thread.
    func details(of id: String) async -> ContactDetails?
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
        // Which groups a contact is in, a contact does not say. Each group
        // is asked for who is in it.
        var groups: [String: [String]] = [:]
        for group in (try? store.groups(matching: nil)) ?? [] where !group.name.isEmpty {
            let members = try? store.unifiedContacts(
                matching: CNContact.predicateForContactsInGroup(withIdentifier: group.identifier),
                keysToFetch: [CNContactIdentifierKey as NSString]
            )
            for member in members ?? [] {
                groups[member.identifier, default: []].append(group.name)
            }
        }

        var records: [ContactRecord] = []
        try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            records.append(ContactRecord(
                id: contact.identifier,
                name: CNContactFormatter.string(from: contact, style: .fullName) ?? "",
                nickname: contact.nickname,
                organization: contact.organizationName,
                isOrganization: contact.contactType == .organization,
                emails: contact.emailAddresses.map { $0.value as String },
                phones: contact.phoneNumbers.map(\.value.stringValue),
                groups: groups[contact.identifier] ?? []
            ))
        }
        return records
    }

    public func details(of id: String) async -> ContactDetails? {
        let keys = [
            CNContactJobTitleKey, CNContactDepartmentNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactPostalAddressesKey, CNContactUrlAddressesKey, CNContactBirthdayKey, CNContactThumbnailImageDataKey,
        ] as [NSString]
        guard let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys) else { return nil }

        func label(_ label: String?) -> String {
            label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
        }
        return ContactDetails(
            id: id,
            jobTitle: contact.jobTitle,
            department: contact.departmentName,
            phones: contact.phoneNumbers.map { .init(label($0.label), $0.value.stringValue) },
            emails: contact.emailAddresses.map { .init(label($0.label), $0.value as String) },
            addresses: contact.postalAddresses.map { address in
                let lines = CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress)
                    .split(whereSeparator: \.isNewline)
                return .init(label(address.label), lines.joined(separator: ", "))
            },
            links: contact.urlAddresses.map { .init(label($0.label), $0.value as String) },
            birthday: contact.birthday,
            picture: contact.thumbnailImageData
        )
    }
}

/// The people and companies in the user's contacts, found by name in the
/// search.
///
/// They are items of the search index, not commands. They are read into
/// memory and never written to disk: macOS guards the contacts, and a copy
/// among Inky's files would be there for any application to read.
///
/// The command "Search Contacts" lists them all on a screen of its own,
/// which reads them from the index as the search does.
@MainActor
public final class ContactsModule: SearchableSource {
    public static let moduleID = "contacts"
    public static let title = "Search Contacts"
    public static let icon = Icon.symbol("person.crop.circle.fill", tint: .orange)
    /// The id of the command that shows the screen.
    public static let searchID = "contacts:search"
    /// The groups of the index's items: people, and companies.
    public static let people = "people"
    public static let organizations = "organizations"

    public let id = ContactsModule.moduleID
    public let info = ModuleInfo(
        title: "Contacts",
        summary: "Find people in your contacts by name, and write to or call them. Asks before it reads them.",
        icon: ContactsModule.icon
    )
    public var onChange: (@MainActor () -> Void)?

    /// Set by the app to show the screen, with what is to be searched for.
    public var onOpen: (@MainActor (String) -> Void)?

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

    public func candidates() async -> [ResultItem] {
        [
            ResultItem(
                id: Self.searchID,
                title: Self.title,
                icon: Self.icon,
                kind: "Command",
                keywords: ["Find Contacts", "People", "Address Book"],
                // Who to search for can be typed along, and being the one
                // argument, lets the command be chosen as a fallback.
                arguments: [Argument(name: "Name", defaultValue: "")],
                actions: [
                    Action("Open", symbol: "person.crop.circle", behavior: .keepOpen, usesArguments: true) { [weak self] context in
                        self?.onOpen?(context.arguments.first ?? "")
                    },
                ]
            ),
        ]
    }

    /// More about one contact, to show it. Nil if Inky may not read the
    /// contacts, or the contact is not there any longer.
    public func details(of id: String) async -> ContactDetails? {
        guard reader.access == .allowed else { return nil }
        return await reader.details(of: id)
    }

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
        if !organization.isEmpty, organization != title { info["organization"] = organization }
        if let email = contact.emails.first { info["email"] = email }
        if let phone = contact.phones.first { info["phone"] = phone }
        if !contact.groups.isEmpty { info["groups"] = contact.groups.joined(separator: "\n") }
        return SearchableItem(
            id: contact.id,
            domain: contact.isOrganization ? organizations : people,
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

    /// The names of the groups a contact is in.
    public static func groups(of item: SearchableItem) -> [String] {
        item.info["groups"]?.split(separator: "\n").map(String.init) ?? []
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
        return actions
    }

    private static func open(_ link: String) throws {
        guard let url = URL(string: link), NSWorkspace.shared.open(url) else {
            throw InkyError("Could not open \(link)")
        }
    }
}
