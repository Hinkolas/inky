import InkyCore
import Observation
import SwiftUI

/// What uninstalling an application would move to the Trash, and which of it
/// the user wants to go.
@Observable
final class UninstallReview {
    let app: ApplicationInfo
    @ObservationIgnored let uninstaller: ApplicationUninstaller

    /// The application first, then what it left behind.
    private(set) var items: [UninstallItem]
    /// By path. An item is missing until it is measured, and for good if it
    /// cannot be looked into.
    private(set) var sizes: [String: Int64] = [:]
    /// Whether what the application left is still being looked for.
    private(set) var isSearching = true
    private(set) var isMeasuring = true
    /// The paths the user unticked. Everything found is ticked to begin with.
    private(set) var excluded: Set<String> = []
    /// The row the keys act on.
    var cursor: String
    var isUninstalling = false

    init(app: ApplicationInfo, uninstaller: ApplicationUninstaller) {
        self.app = app
        self.uninstaller = uninstaller
        items = [UninstallItem(path: app.path, isApplication: true)]
        cursor = app.path
        load()
    }

    private func load() {
        Task { [app, uninstaller] in
            // Folders are listed and read off the main thread: a large
            // application takes a moment to add up.
            items = await Task.detached(priority: .userInitiated) {
                uninstaller.items(for: app, installed: uninstaller.installedApplications())
            }.value
            isSearching = false

            for item in items {
                sizes[item.path] = await Task.detached(priority: .userInitiated) {
                    ApplicationUninstaller.size(of: item.path)
                }.value
            }
            isMeasuring = false
        }
    }

    /// What goes to the Trash.
    var chosen: [UninstallItem] {
        items.filter { !excluded.contains($0.path) }
    }

    func isChosen(_ item: UninstallItem) -> Bool {
        !excluded.contains(item.path)
    }

    func toggle(_ item: UninstallItem) {
        if excluded.remove(item.path) == nil { excluded.insert(item.path) }
    }

    func toggleCurrent() {
        if let item = items.first(where: { $0.path == cursor }) { toggle(item) }
    }

    /// Ticks everything, or nothing if everything already is.
    func toggleAll() {
        excluded = excluded.isEmpty ? Set(items.map(\.path)) : []
    }

    func moveCursor(by offset: Int) {
        let current = items.firstIndex { $0.path == cursor } ?? 0
        cursor = items[(current + offset + items.count) % items.count].path
    }

    /// The folder the item is in, as it is shown.
    func location(of item: UninstallItem) -> String {
        uninstaller.abbreviated(item.folder)
    }

    /// How much was found and how much of it goes: the title of the list.
    var summary: String {
        guard !isSearching else { return "Looking for what it left behind…" }
        let chosen = chosen
        var summary = "\(chosen.count) of \(items.count) selected"
        if !isMeasuring, !chosen.isEmpty {
            let total = chosen.reduce(Int64(0)) { $0 + (sizes[$1.path] ?? 0) }
            summary += "  ·  \(Self.format(total))"
        }
        return summary
    }

    /// The size of the item, once it is known.
    func size(of item: UninstallItem) -> String {
        sizes[item.path].map(Self.format) ?? (isMeasuring ? "" : "–")
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Shows what uninstalling an application moves to the Trash, each file with
/// a box to keep it. Nothing goes before the user asks for it here.
struct UninstallReviewScreen: View {
    let model: LauncherModel
    let review: UninstallReview

    /// Of the body card.
    static let size = UninstallBrowserScreen.size

    private static let top = "inky.uninstall.files.top"
    private static let end = "inky.uninstall.files.end"
    /// As much of a name as fits next to the button.
    private static let longestName = 30

    /// The keys of this screen, shown below the card.
    static var hints: some View {
        KeyHintBar {
            KeyHint(["↑"], ["↓"], title: "Move")
            KeyHint(["↵"], title: "Select")
            KeyHint(["⌘", "A"], title: "Select All")
            KeyHint(["⌘", "O"], title: "Show in Finder")
            KeyHint(["esc"], title: "Back")
        }
    }

    var body: some View {
        let name = review.app.name
        let canUninstall = !review.isSearching && !review.isUninstalling && !review.chosen.isEmpty

        CommandScreen(
            icon: .file(path: review.app.path),
            path: [
                ApplicationModule.uninstallTitle,
                name.count > Self.longestName ? name.prefix(Self.longestName - 1).trimmingCharacters(in: .whitespaces) + "…" : name,
            ],
            size: Self.size
        ) {
            CapsuleButton(
                title: review.isUninstalling ? "Uninstalling…" : "Uninstall",
                keys: ["⌘", "↵"],
                isProminent: true,
                isDestructive: true
            ) {
                model.uninstall(review)
            }
            .disabled(!canUninstall)
            .opacity(canUninstall ? 1 : 0.5)
        } content: {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top)
                    ListHeader(review.summary)
                    ForEach(review.items) { item in
                        row(item)
                    }
                    footer.id(Self.end)
                }
            }
            .scrollIndicators(.never)
            .onChange(of: review.cursor) { previous, cursor in
                proxy.reveal(cursor, after: previous, among: review.items.map(\.path), top: Self.top, end: Self.end)
            }
        }
    }

    private func row(_ item: UninstallItem) -> some View {
        let isSelected = item.path == review.cursor
        return ListRow(title: item.name, subtitle: review.location(of: item), isSelected: isSelected) {
            HStack(spacing: 11) {
                Button {
                    review.toggle(item)
                } label: {
                    Checkbox(isOn: review.isChosen(item), isOnAccent: isSelected)
                        // Easier to hit than it is to see.
                        .padding(6)
                        .contentShape(Rectangle())
                        .padding(-6)
                }
                .buttonStyle(.plain)
                IconView(icon: .file(path: item.path), size: 24)
            }
        } trailing: {
            Text(review.size(of: item))
                .font(.system(size: 13.5))
                .monospacedDigit()
                .foregroundStyle(Theme.quiet(isSelected: isSelected))
                .lineLimit(1)
        }
        .frame(height: LauncherMetrics.rowHeight + 1)
        .id(item.path)
        .simultaneousGesture(TapGesture().onEnded {
            review.cursor = item.path
        })
    }

    /// Ends the list, and says where everything goes.
    private var footer: some View {
        let note = if review.isSearching {
            ""
        } else if review.items.count == 1 {
            "Nothing else of it was found. It goes to the Trash, where it can be put back."
        } else {
            "Everything selected goes to the Trash, where it can be put back."
        }
        return Text(note)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .padding(.bottom, 5)
            .frame(height: LauncherMetrics.sectionHeaderHeight)
    }
}
