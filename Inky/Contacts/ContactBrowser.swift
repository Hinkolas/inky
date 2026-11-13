import AppKit
import InkyCore
import Observation
import SwiftUI

/// The state of the contacts' screen: what is filtered and what is selected.
///
/// The contacts are the items the module wrote to the search index, the
/// same ones the search finds. Only the selected one is read from the Mac's
/// contacts again, for what the index does not hold of it.
@Observable
final class ContactBrowser {
    /// What the list is narrowed down to.
    enum Filter: Hashable {
        case all, people, organizations
        /// The contacts in a group of the Mac's contacts, by its name.
        case group(String)

        var title: String {
            switch self {
            case .all: "All Contacts"
            case .people: "People"
            case .organizations: "Companies"
            case .group(let name): name
            }
        }

        var symbol: String {
            switch self {
            case .all: "person.2"
            case .people: "person"
            case .organizations: "building.2"
            case .group: "person.3"
            }
        }

        func includes(_ item: SearchableItem) -> Bool {
            switch self {
            case .all: true
            case .people: item.domain == ContactsModule.people
            case .organizations: item.domain == ContactsModule.organizations
            case .group(let name): ContactsModule.groups(of: item).contains(name)
            }
        }
    }

    /// A letter the names below it begin with, or a contact.
    enum Line: Identifiable {
        case header(String)
        case contact(SearchableItem)

        var id: String {
            switch self {
            case .header(let title): "section.\(title)"
            case .contact(let item): "contact.\(item.id)"
            }
        }
    }

    /// A contact with what it is matched by, worked out once.
    private struct Entry {
        let item: SearchableItem
        let title: FuzzyMatcher.Target
        let keywords: [FuzzyMatcher.Target]
    }

    @ObservationIgnored let index: SearchIndex
    @ObservationIgnored let module: ContactsModule

    var query: String {
        didSet {
            guard query != oldValue else { return }
            // What is found for something else begins with its best match.
            selectedID = nil
            list()
        }
    }

    var filter = Filter.all {
        didSet {
            guard filter != oldValue else { return }
            selectedID = nil
            list()
        }
    }

    var selectedID: String? {
        didSet { if selectedID != oldValue { loadDetails() } }
    }

    /// Whether Inky may read the contacts.
    private(set) var access: ContactsAccess
    /// The groups there are, by name, and how many contacts each has.
    private(set) var groups: [(name: String, count: Int)] = []
    /// What the arrow keys go through.
    private(set) var contacts: [SearchableItem] = []
    /// What the list shows.
    private(set) var lines: [Line] = []
    /// More about the selected contact, once it is read.
    private(set) var details: ContactDetails?
    /// The selected contact's picture, if it has one.
    private(set) var picture: NSImage?

    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var generation = 0

    init(index: SearchIndex, module: ContactsModule, query: String = "") {
        self.index = index
        self.module = module
        self.query = query
        access = module.access
        reload()
    }

    /// Reads the contacts from the index again, as when they changed.
    func reload() {
        access = module.access
        entries = index.items(of: module.id)
            .sorted { first, second in
                let order = first.title.localizedStandardCompare(second.title)
                return order != .orderedSame ? order == .orderedAscending : first.id < second.id
            }
            .map { Entry(item: $0, title: FuzzyMatcher.Target($0.title), keywords: $0.keywords.map(FuzzyMatcher.Target.init)) }

        var counts: [String: Int] = [:]
        for entry in entries {
            for group in ContactsModule.groups(of: entry.item) { counts[group, default: 0] += 1 }
        }
        groups = counts
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (name: $0.key, count: $0.value) }
        // A group that is gone lists nothing. Everything is listed instead.
        if case .group(let name) = filter, counts[name] == nil {
            filter = .all
        } else {
            list()
        }
    }

    var total: Int { entries.count }

    func count(_ filter: Filter) -> Int {
        entries.count { filter.includes($0.item) }
    }

    /// Lists the contacts that pass the filter and the query: by name under
    /// the letter they begin with when nothing is typed, best match first
    /// otherwise.
    private func list() {
        let listed = entries.filter { filter.includes($0.item) }
        let pattern = FuzzyMatcher.Pattern(query)
        if pattern.isEmpty {
            contacts = listed.map(\.item)
            var lines: [Line] = []
            var letter: String?
            for item in contacts {
                let initial = Self.initial(of: item.title)
                if initial != letter {
                    letter = initial
                    lines.append(.header(initial))
                }
                lines.append(.contact(item))
            }
            self.lines = lines
        } else {
            contacts = listed
                .compactMap { entry -> (item: SearchableItem, score: Double)? in
                    var best = FuzzyMatcher.score(pattern, in: entry.title)
                    for keyword in entry.keywords {
                        if let score = FuzzyMatcher.score(pattern, in: keyword).map({ $0 * 0.85 }), score > best ?? 0 {
                            best = score
                        }
                    }
                    return best.map { (entry.item, $0) }
                }
                .sorted { $0.score > $1.score }
                .map(\.item)
            lines = contacts.isEmpty ? [] : [.header(filter == .all ? "Contacts" : filter.title)] + contacts.map(Line.contact)
        }
        loadDetails()
    }

    /// The letter a name is listed under, without what is written over it.
    private static func initial(of name: String) -> String {
        guard let first = name.first, first.isLetter else { return "#" }
        return String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
    }

    // MARK: - Selection

    /// The selected contact, or the first one if the selection is not listed.
    var selected: SearchableItem? {
        contacts.first { $0.id == selectedID } ?? contacts.first
    }

    func moveSelection(by offset: Int) {
        guard let selected, let current = contacts.firstIndex(where: { $0.id == selected.id }) else { return }
        selectedID = contacts[min(max(current + offset, 0), contacts.count - 1)].id
    }

    /// Every filter there is, in the order of the sidebar.
    var filters: [Filter] {
        [.all, .people, .organizations] + groups.map { .group($0.name) }
    }

    func cycleFilter(by offset: Int) {
        let filters = filters
        let current = filters.firstIndex(of: filter) ?? 0
        filter = filters[(current + offset + filters.count) % filters.count]
    }

    /// The details of `contact`, if they are the ones that were read last.
    func details(of contact: SearchableItem) -> ContactDetails? {
        details?.id == contact.id ? details : nil
    }

    private func loadDetails() {
        guard let contact = selected else {
            generation += 1
            details = nil
            picture = nil
            return
        }
        guard details?.id != contact.id else { return }
        generation += 1
        let generation = generation
        Task {
            let details = await module.details(of: contact.id)
            guard generation == self.generation else { return }
            self.details = details
            picture = details?.picture.flatMap(NSImage.init(data:))
        }
    }
}

// MARK: - Screen

/// The contacts: a sidebar to narrow them down to people, companies or a
/// group, the list, and a side panel with the selected contact and what can
/// be done with it.
struct ContactBrowserScreen: View {
    let model: LauncherModel
    @Bindable var browser: ContactBrowser
    let focus: LauncherFocus

    /// Of the body card.
    static let size = CGSize(width: 940, height: 500)

    private static let top = "inky.contacts.top"
    private static let end = "inky.contacts.end"

    var body: some View {
        let selected = browser.selected
        let total = browser.total

        CommandScreen(
            icon: ContactsModule.icon,
            path: [ContactsModule.title],
            size: Self.size
        ) {
            FilterField(
                text: $browser.query,
                prompt: browser.access != .allowed ? "Filter contacts"
                    : total == 1 ? "Filter 1 contact" : "Filter \(total.formatted()) contacts",
                focus: focus
            )
        } accessory: {
            EmptyView()
        } content: {
            if browser.access == .allowed {
                HStack(spacing: 0) {
                    Sidebar { sidebar }

                    list(selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    SidePanel(width: 300) {
                        if let selected {
                            card(selected)
                        }
                    }
                }
            } else {
                notice
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: browser.index.revision) { browser.reload() }
    }

    /// Says that Inky does not read the contacts, and where to change that.
    private var notice: some View {
        let isDenied = browser.access == .denied
        return VStack(spacing: 8) {
            Image(systemName: isDenied ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 26))
                .foregroundStyle(isDenied ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .padding(.bottom, 4)
            Text(isDenied ? "Inky may not read your contacts" : "Inky has not asked for your contacts yet")
                .font(.system(size: 14, weight: .medium))
            Text(isDenied
                ? "Allow Inky under Privacy & Security → Contacts in System Settings."
                : "Allow it in Inky's settings. Your contacts stay on your Mac, and nothing of them is written to disk.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            CapsuleButton(title: "Open Settings", keys: ["↵"], action: model.configureContacts)
                .padding(.top, 8)
        }
    }

    // MARK: - Sidebar

    @ViewBuilder private var sidebar: some View {
        PanelLabel("Type")
            .padding(.horizontal, 9)
            .padding(.top, 7)
            .padding(.bottom, 9)
        ForEach([ContactBrowser.Filter.all, .people, .organizations], id: \.self) { filter in
            SidebarRow(
                title: filter.title,
                symbol: filter.symbol,
                count: browser.count(filter),
                isSelected: filter == browser.filter
            ) {
                browser.filter = filter
            }
        }

        if !browser.groups.isEmpty {
            PanelLabel("Groups")
                .padding(.horizontal, 9)
                .padding(.top, 18)
                .padding(.bottom, 9)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(browser.groups, id: \.name) { group in
                            let filter = ContactBrowser.Filter.group(group.name)
                            SidebarRow(
                                title: group.name,
                                symbol: filter.symbol,
                                count: group.count,
                                isSelected: filter == browser.filter
                            ) {
                                browser.filter = filter
                            }
                            .id(group.name)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: browser.filter) { _, filter in
                    if case .group(let name) = filter { proxy.scrollTo(name) }
                }
            }
        }
    }

    // MARK: - List

    @ViewBuilder private func list(_ selected: SearchableItem?) -> some View {
        if browser.contacts.isEmpty {
            VStack(spacing: 6) {
                Text(browser.total == 0 ? "No contacts" : "No matching contacts")
                    .font(.system(size: 14, weight: .medium))
                if browser.total == 0 {
                    Text("People and companies in your contacts are listed here.")
                        .font(.system(size: 12.5))
                }
            }
            .foregroundStyle(.secondary)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.top)
                        ForEach(browser.lines) { line in
                            switch line {
                            case .header(let title):
                                PanelLabel(title)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 9)
                                    .frame(height: 34)
                            case .contact(let item):
                                row(item, isSelected: item.id == selected?.id)
                            }
                        }
                        Color.clear.frame(height: 10).id(Self.end)
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.never)
                .padding(.vertical, LauncherMetrics.panelInset)
                .onChange(of: selected?.id) { previous, id in
                    guard let id else { return }
                    proxy.reveal(id, after: previous, among: browser.contacts.map(\.id), top: Self.top, end: Self.end)
                }
            }
        }
    }

    private func row(_ item: SearchableItem, isSelected: Bool) -> some View {
        DetailRow(
            title: item.title,
            subtitle: item.subtitle ?? (item.domain == ContactsModule.organizations ? "Company" : "Contact"),
            isSelected: isSelected
        ) {
            ContactAvatar(item: item, isSelected: isSelected)
        }
        .id(item.id)
        .onTapGesture(count: 2) {
            browser.selectedID = item.id
            model.runPrimaryAction(on: item)
        }
        .simultaneousGesture(TapGesture().onEnded {
            browser.selectedID = item.id
        })
    }

    // MARK: - Card

    @ViewBuilder private func card(_ contact: SearchableItem) -> some View {
        let details = browser.details(of: contact)

        HStack(spacing: 12) {
            ContactAvatar(item: contact, picture: details == nil ? nil : browser.picture, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                if let line = ContactDescription.line(below: contact, details: details) {
                    Text(line)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)

        // As much of it as the actions leave room for, the ways to reach
        // the contact first.
        MetadataList(rows: ContactDescription.facts(about: contact, details: details))
            .padding(.top, 16)
            .padding(.horizontal, 2)
            // May be less than it takes: what does not fit is cut off.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
            .layoutPriority(-1)

        PanelDivider()
            .padding(.vertical, 14)

        ActionList(actions: model.actions(for: contact))
            .padding(.horizontal, -4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Parts

/// What stands for a contact: its picture, or the letters its name begins
/// with on a color of its own. A company has a building.
struct ContactAvatar: View {
    let item: SearchableItem
    var picture: NSImage?
    var size: CGFloat = 30
    var isSelected = false

    /// Told apart by color. Which one a contact gets stays the same.
    private static let colors: [Color] = [.orange, .purple, .green, .blue, .pink, .teal, .indigo, .red]

    var body: some View {
        Group {
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(color.gradient)
                    .overlay {
                        if item.domain == ContactsModule.organizations {
                            Image(systemName: "building.2.fill")
                                .font(.system(size: size * 0.4, weight: .semibold))
                        } else {
                            Text(Self.initials(of: item.title))
                                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        }
                    }
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            if isSelected { Circle().strokeBorder(.white.opacity(0.5)) }
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        // Not the hash Swift makes, which is another one every launch.
        let sum = item.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.colors[sum % Self.colors.count]
    }

    /// The first letters of the first and the last word of a name. Titles
    /// such as "Dr." are not part of it.
    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
            .filter { !$0.hasSuffix(".") && ($0.first?.isLetter ?? false) }
        guard let first = words.first?.first else {
            return name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
        }
        let last = words.count > 1 ? words.last?.first : nil
        return (String(first) + (last.map { String($0) } ?? "")).uppercased()
    }
}

/// How a contact is put into words.
enum ContactDescription {
    /// What stands below a contact's name: what the person does and where.
    static func line(below contact: SearchableItem, details: ContactDetails?) -> String? {
        let parts = [details?.jobTitle, details?.department, contact.info["organization"]]
            .compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return contact.domain == ContactsModule.organizations ? "Company" : nil
    }

    /// What the side panel says about a contact: how to reach it first.
    /// Until the contact is read, what the index holds of it.
    static func facts(about contact: SearchableItem, details: ContactDetails?) -> [(name: String, value: String)] {
        guard let details else {
            return [("phone", contact.info["phone"]), ("email", contact.info["email"])]
                .compactMap { name, value in value.map { (name, $0) } }
        }
        var facts: [(name: String, value: String)] = []
        facts += details.phones.map { ($0.label.isEmpty ? "phone" : $0.label, $0.value) }
        facts += details.emails.map { ($0.label.isEmpty ? "email" : $0.label, $0.value) }
        if let birthday = details.birthday, let text = self.birthday(birthday) {
            facts.append(("birthday", text))
        }
        facts += details.addresses.map { ($0.label.isEmpty ? "address" : $0.label, $0.value) }
        facts += details.links.map { ($0.label.isEmpty ? "link" : $0.label, $0.value) }
        let groups = ContactsModule.groups(of: contact)
        if !groups.isEmpty {
            facts.append((groups.count == 1 ? "group" : "groups", groups.joined(separator: ", ")))
        }
        return facts
    }

    /// "24 December 1985", or without the year where the contact has none.
    private static func birthday(_ components: DateComponents) -> String? {
        var components = components
        components.calendar = Calendar(identifier: .gregorian)
        let hasYear = components.year != nil && components.year != NSDateComponentUndefined
        // A leap year, so that the 29th of February is a day.
        if !hasYear { components.year = 2000 }
        guard let date = components.date else { return nil }
        let style = Date.FormatStyle.dateTime.day().month(.wide)
        return date.formatted(hasYear ? style.year() : style)
    }
}
