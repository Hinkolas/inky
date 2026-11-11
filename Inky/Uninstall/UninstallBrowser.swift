import InkyCore
import Observation
import SwiftUI

/// The state of the list an application is chosen from to be uninstalled.
@Observable
final class UninstallBrowser {
    @ObservationIgnored let uninstaller: ApplicationUninstaller
    /// Every application the user can remove, by name.
    private(set) var applications: [ApplicationInfo] = []
    var query = ""
    var selectedID: String?

    init(uninstaller: ApplicationUninstaller) {
        self.uninstaller = uninstaller
        reload()
    }

    /// Reads the applications again, as after one of them went.
    func reload() {
        Task { [uninstaller] in
            applications = await Task.detached(priority: .userInitiated) {
                uninstaller.installedApplications()
                    .filter(uninstaller.canUninstall)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value
        }
    }

    /// The applications that pass the query: by name when nothing is typed,
    /// best match first otherwise.
    var visible: [ApplicationInfo] {
        let pattern = FuzzyMatcher.Pattern(query)
        guard !pattern.isEmpty else { return applications }
        return applications
            .compactMap { app -> (app: ApplicationInfo, score: Double)? in
                let scores = ([app.name] + app.alternateNames).compactMap {
                    FuzzyMatcher.score(pattern, in: FuzzyMatcher.Target($0))
                }
                return scores.max().map { (app, $0) }
            }
            .sorted { $0.score > $1.score }
            .map(\.app)
    }

    /// The selected application, or the first one if the selection is not listed.
    var selected: ApplicationInfo? {
        let visible = visible
        return visible.first { $0.id == selectedID } ?? visible.first
    }

    func moveSelection(by offset: Int) {
        let visible = visible
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visible[(current + offset + visible.count) % visible.count].id
    }

    /// The folder the application is in, as it is shown.
    func location(of app: ApplicationInfo) -> String {
        uninstaller.abbreviated((app.path as NSString).deletingLastPathComponent)
    }
}

/// Lists the applications that can be uninstalled. Choosing one shows what
/// would go with it; nothing is removed from here.
struct UninstallBrowserScreen: View {
    let model: LauncherModel
    @Bindable var browser: UninstallBrowser
    @FocusState private var isFilterFocused: Bool

    /// Of the body card.
    static let size = CGSize(width: 780, height: 440)

    private static let top = "inky.uninstall.top"
    private static let end = "inky.uninstall.end"

    /// The keys of this screen, shown below the card.
    static var hints: some View {
        KeyHintBar {
            KeyHint(["↑"], ["↓"], title: "Move")
            KeyHint(["↵"], title: "Choose")
            KeyHint(["esc"], title: "Back")
        }
    }

    var body: some View {
        let visible = browser.visible
        let selected = browser.selected
        let total = browser.applications.count

        CommandScreen(
            icon: ApplicationModule.uninstallIcon,
            path: [ApplicationModule.uninstallTitle],
            size: Self.size
        ) {
            FilterField(
                text: $browser.query,
                prompt: total == 1 ? "Filter 1 application" : "Filter \(total) applications",
                focus: $isFilterFocused
            )
        } accessory: {
            EmptyView()
        } content: {
            list(visible, selected: selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { isFilterFocused = true }
    }

    @ViewBuilder private func list(_ applications: [ApplicationInfo], selected: ApplicationInfo?) -> some View {
        if applications.isEmpty {
            // Empty for a moment while the applications are read, too.
            if !browser.applications.isEmpty {
                Text("No matching applications")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.top)
                        ListHeader("Applications")
                        ForEach(applications) { app in
                            let isSelected = app.id == selected?.id
                            ListRow(
                                title: app.name,
                                subtitle: browser.location(of: app),
                                isSelected: isSelected,
                                trailingInset: isSelected ? 8 : 10
                            ) {
                                IconView(icon: .file(path: app.path), size: 24)
                            } trailing: {
                                if isSelected {
                                    HStack(spacing: 6) {
                                        Text("Uninstall…")
                                            .font(.system(size: 13.5, weight: .semibold))
                                            .lineLimit(1)
                                            .padding(.trailing, 2)
                                        Keycap(["↵"], tone: .onAccent)
                                    }
                                }
                            }
                            .frame(height: LauncherMetrics.rowHeight + 1)
                            .id(app.id)
                            .onTapGesture(count: 2) {
                                model.reviewUninstall(of: app)
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                browser.selectedID = app.id
                            })
                        }
                        // Keeps the last row clear of the card's corners.
                        Color.clear.frame(height: 12).id(Self.end)
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: selected?.id) { previous, id in
                    guard let id else { return }
                    proxy.reveal(id, after: previous, among: applications.map(\.id), top: Self.top, end: Self.end)
                }
            }
        }
    }
}
