import AppKit
import InkyCore
import Observation
import SwiftUI

/// The state of the quicklink browser: what is filtered and what is selected.
@Observable
final class QuicklinkBrowser {
    enum Filter: Hashable, CaseIterable {
        case all, websites, files, appLinks

        var title: String {
            switch self {
            case .all: "All"
            case .websites: "Websites"
            case .files: "Files"
            case .appLinks: "App Links"
            }
        }

        var symbol: String {
            switch self {
            case .all: "link"
            case .websites: "globe"
            case .files: "folder"
            case .appLinks: "arrow.up.forward.app"
            }
        }

        func includes(_ quicklink: Quicklink) -> Bool {
            switch self {
            case .all: true
            case .websites: quicklink.kind == .website
            case .files: quicklink.kind == .file
            case .appLinks: quicklink.kind == .appLink
            }
        }
    }

    @ObservationIgnored let store: QuicklinkStore
    var query = ""
    var filter = Filter.all
    var selectedID: UUID?

    init(store: QuicklinkStore) {
        self.store = store
    }

    func count(_ filter: Filter) -> Int {
        store.quicklinks.count(where: filter.includes)
    }

    /// The quicklinks that pass the filter and the query: by name when
    /// nothing is typed, best match first otherwise.
    var visible: [Quicklink] {
        let listed = store.quicklinks.filter(filter.includes)
        let pattern = FuzzyMatcher.Pattern(query)
        guard !pattern.isEmpty else {
            return listed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        return listed
            .compactMap { quicklink -> (quicklink: Quicklink, score: Double)? in
                if let score = FuzzyMatcher.score(pattern, in: FuzzyMatcher.Target(quicklink.name)) {
                    return (quicklink, score)
                }
                return quicklink.link.localizedCaseInsensitiveContains(text) ? (quicklink, 0) : nil
            }
            .sorted { $0.score > $1.score }
            .map(\.quicklink)
    }

    /// The selected quicklink, or the first one if the selection is not listed.
    var selected: Quicklink? {
        let visible = visible
        return visible.first { $0.id == selectedID } ?? visible.first
    }

    func moveSelection(by offset: Int) {
        let visible = visible
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visible[(current + offset + visible.count) % visible.count].id
    }

    func cycleFilter(by offset: Int) {
        let filters = Filter.allCases
        let current = filters.firstIndex(of: filter) ?? 0
        filter = filters[(current + offset + filters.count) % filters.count]
    }

    /// Moves the selection off a quicklink that is about to go away.
    func selectNeighbor(of id: UUID) {
        let visible = visible
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return }
        let neighbor = index + 1 < visible.count ? index + 1 : index - 1
        selectedID = visible.indices.contains(neighbor) ? visible[neighbor].id : nil
    }
}

/// Lists the user's quicklinks: a sidebar to narrow them down, the list, and
/// a side panel with the selected quicklink and what can be done with it.
struct QuicklinkBrowserScreen: View {
    let model: LauncherModel
    @Bindable var browser: QuicklinkBrowser
    let focus: LauncherFocus

    /// Of the body card.
    static let size = CGSize(width: 940, height: 500)

    var body: some View {
        let visible = browser.visible
        let selected = browser.selected
        let total = browser.count(.all)

        CommandScreen(
            icon: .symbol("link", tint: .purple),
            path: ["Quicklinks"],
            size: Self.size
        ) {
            FilterField(
                text: $browser.query,
                prompt: total == 1 ? "Filter 1 quicklink" : "Filter \(total) quicklinks",
                focus: focus
            )
        } accessory: {
            CapsuleButton(title: "New", keys: ["⌘", "N"]) {
                model.editQuicklink(nil)
            }
        } content: {
            HStack(spacing: 0) {
                Sidebar {
                    PanelLabel("Type")
                        .padding(.horizontal, 9)
                        .padding(.top, 7)
                        .padding(.bottom, 9)
                    ForEach(QuicklinkBrowser.Filter.allCases, id: \.self) { filter in
                        SidebarRow(
                            title: filter.title,
                            symbol: filter.symbol,
                            count: browser.count(filter),
                            isSelected: filter == browser.filter
                        ) {
                            browser.filter = filter
                        }
                    }
                }

                list(visible, selected: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                SidePanel(width: 280) {
                    if let selected {
                        inspector(selected)
                    }
                }
            }
        }
    }

    @ViewBuilder private func list(_ quicklinks: [Quicklink], selected: Quicklink?) -> some View {
        if quicklinks.isEmpty {
            VStack(spacing: 6) {
                Text(browser.query.isEmpty ? "No quicklinks here yet" : "No matching quicklinks")
                    .font(.system(size: 14, weight: .medium))
                Text("Press ⌘N to create one.")
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(.secondary)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        PanelLabel(browser.filter.title)
                            .padding(.horizontal, 12)
                            .padding(.top, 9)
                            .frame(height: 34)
                        ForEach(quicklinks) { quicklink in
                            let arguments = quicklink.template.arguments.count
                            DetailRow(
                                icon: QuicklinkModule.icon(for: quicklink.template),
                                title: quicklink.name,
                                subtitle: QuicklinkModule.summary(of: quicklink.link),
                                trailing: arguments == 0 ? nil : arguments == 1 ? "1 argument" : "\(arguments) arguments",
                                isSelected: quicklink.id == selected?.id
                            )
                            .id(quicklink.id)
                            .onTapGesture(count: 2) {
                                model.editQuicklink(quicklink)
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                browser.selectedID = quicklink.id
                            })
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
                .padding(.vertical, LauncherMetrics.panelInset)
                .onChange(of: selected?.id) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    @ViewBuilder private func inspector(_ quicklink: Quicklink) -> some View {
        let arguments = quicklink.template.arguments.map(\.name)

        PreviewBox(text: quicklink.link)
            .lineLimit(6)
        MetadataList(rows: [
            ("Type", kindTitle(quicklink.kind)),
            ("Opens with", quicklink.openWith.map(QuicklinkDraft.applicationName) ?? "Default App"),
            ("Arguments", arguments.isEmpty ? "None" : arguments.joined(separator: ", ")),
        ])
        .padding(.top, 14)
        .padding(.horizontal, 2)

        PanelDivider()
            .padding(.vertical, 14)

        ActionList(actions: model.actions(for: quicklink, in: browser))
            .padding(.horizontal, -4)
    }

    private func kindTitle(_ kind: Quicklink.Kind) -> String {
        switch kind {
        case .website: "Website"
        case .file: "File or folder"
        case .appLink: "App link"
        }
    }
}
