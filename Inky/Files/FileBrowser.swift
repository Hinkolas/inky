import AppKit
import InkyCore
import Observation
import SwiftUI

/// The state of the file search's screen: what is asked for, what was found,
/// and what is selected.
///
/// With nothing typed it lists the files that were opened lately. What is
/// found comes from the Spotlight index; only the selected file is read, to
/// show it.
@Observable
final class FileBrowser {
    var query: String {
        didSet {
            guard query != oldValue else { return }
            // What is found for something else begins with its best match.
            selectedID = nil
            search()
        }
    }

    var filter = FileFilter.all {
        didSet {
            guard filter != oldValue else { return }
            selectedID = nil
            search()
        }
    }

    var selectedID: String? {
        didSet { if selectedID != oldValue { loadPreview() } }
    }

    private(set) var files: [FileHit] = []
    /// What `files` were found for.
    private(set) var listed = FileQuery(text: "")
    /// False until the first search came back.
    private(set) var isLoaded = false
    /// What the selected file is shown by, once it is read.
    private(set) var preview: (id: String, content: FilePreview)?

    /// The folders that are searched. Nil is the user's home folder.
    @ObservationIgnored private let scopes: [String]?
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private var previewing: Task<Void, Never>?
    /// What was read lately, so that going back to a file shows it at once.
    @ObservationIgnored private var previews: [String: FilePreview] = [:]

    /// How many files are listed.
    private static let limit = 100
    /// How many Spotlight is asked for, to rank them.
    private static let gatherLimit = 1500
    /// The room the side panel has for a picture, at most.
    static let previewSize = CGSize(width: 440, height: 300)

    init(query: String = "", scopes: [String]? = nil) {
        self.query = query
        self.scopes = scopes
        search(immediately: true)
    }

    /// Searches again, as when the launcher comes back and what was opened
    /// lately may have changed.
    func reload() {
        search(immediately: true)
    }

    private func search(immediately: Bool = false) {
        searching?.cancel()
        let asked = FileQuery(text: query, filter: filter)
        searching = Task {
            // Wait for a pause in typing.
            if !immediately { try? await Task.sleep(for: .milliseconds(80)) }
            guard !Task.isCancelled else { return }
            let found = await FileSearch.run(asked, in: scopes, limit: Self.limit, gatherLimit: Self.gatherLimit)
            guard !Task.isCancelled else { return }
            files = found
            listed = asked
            isLoaded = true
            loadPreview()
        }
    }

    // MARK: - Selection

    /// The selected file, or the first one if the selection is not listed.
    var selected: FileHit? {
        files.first { $0.id == selectedID } ?? files.first
    }

    func moveSelection(by offset: Int) {
        guard let selected, let current = files.firstIndex(where: { $0.id == selected.id }) else { return }
        selectedID = files[min(max(current + offset, 0), files.count - 1)].id
    }

    func cycleFilter(by offset: Int) {
        let filters = FileFilter.allCases
        let current = filters.firstIndex(of: filter) ?? 0
        filter = filters[(current + offset + filters.count) % filters.count]
    }

    /// The preview of `file`, if it is the one that was read last.
    func preview(of file: FileHit) -> FilePreview? {
        preview?.id == file.id ? preview?.content : nil
    }

    private func loadPreview() {
        guard let file = selected else {
            previewing?.cancel()
            preview = nil
            return
        }
        guard preview?.id != file.id else { return }
        previewing?.cancel()
        if let known = previews[file.id] {
            preview = (file.id, known)
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        previewing = Task {
            let content = await FilePreviewLoader.load(file, size: Self.previewSize, scale: scale)
            guard !Task.isCancelled else { return }
            let loaded = FilePreview(content, scale: scale)
            if previews.count >= 60 { previews.removeAll() }
            previews[file.id] = loaded
            preview = (file.id, loaded)
        }
    }
}

// MARK: - Screen

/// The file search: the list of what was found, and a side panel that shows
/// the selected file and says what the index knows about it.
struct FileBrowserScreen: View {
    let model: LauncherModel
    @Bindable var browser: FileBrowser
    let focus: LauncherFocus

    /// Of the body card.
    static let size = CGSize(width: 940, height: 500)

    private static let top = "inky.files.top"
    private static let end = "inky.files.end"

    /// The keys of this screen, shown below the card.
    static var hints: some View {
        KeyHintBar {
            KeyHint(["↵"], title: "Open")
            KeyHint(["⌘", "↵"], title: "Show in Finder")
            KeyHint(["⌘", "C"], title: "Copy File")
            KeyHint(["⇧", "⌘", "C"], title: "Copy Path")
            KeyHint(["⇥"], title: "Type")
        }
    }

    var body: some View {
        let selected = browser.selected

        CommandScreen(
            icon: FileModule.icon,
            path: [FileModule.title],
            size: Self.size
        ) {
            FilterField(text: $browser.query, prompt: "Search by name", focus: focus)
        } accessory: {
            typeMenu
        } content: {
            HStack(spacing: 0) {
                list(selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                SidePanel(width: 470) {
                    if let selected {
                        let preview = browser.preview(of: selected)
                        FilePreviewView(file: selected, preview: preview)
                        MetadataList(rows: FileDescription.facts(about: selected, preview: preview))
                            .padding(.top, 14)
                            .padding(.horizontal, 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var typeMenu: some View {
        Menu {
            Picker("Type", selection: $browser.filter) {
                ForEach(FileFilter.allCases, id: \.self) { filter in
                    Label(filter.title, systemImage: filter.symbol).tag(filter)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            BarMenuLabel(title: browser.filter.title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show only files of one type")
    }

    // MARK: - List

    @ViewBuilder private func list(_ selected: FileHit?) -> some View {
        let isRecents = browser.listed.isRecents
        if browser.files.isEmpty {
            // Empty for a moment while the first search is out, too.
            if browser.isLoaded {
                VStack(spacing: 6) {
                    Text(isRecents ? "Nothing opened lately" : "No matching files")
                        .font(.system(size: 14, weight: .medium))
                    Text(isRecents
                        ? "Type to search your home folder by name."
                        : "Files are found by name, through the Spotlight index.")
                        .font(.system(size: 12.5))
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.top)
                        PanelLabel(title(isRecents: isRecents))
                            .padding(.horizontal, 12)
                            .padding(.top, 9)
                            .frame(height: 34)
                        ForEach(browser.files) { file in
                            row(file, isSelected: file.id == selected?.id, isRecents: isRecents)
                        }
                        Color.clear.frame(height: 10).id(Self.end)
                    }
                    .padding(.leading, LauncherMetrics.panelInset)
                    .padding(.trailing, 2)
                }
                .scrollIndicators(.never)
                .padding(.vertical, LauncherMetrics.panelInset)
                .onChange(of: selected?.id) { previous, id in
                    guard let id else { return }
                    proxy.reveal(id, after: previous, among: browser.files.map(\.id), top: Self.top, end: Self.end)
                }
            }
        }
    }

    private func title(isRecents: Bool) -> String {
        let filter = browser.listed.filter
        if isRecents { return filter == .all ? "Opened Lately" : "\(filter.title) Opened Lately" }
        return filter == .all ? "Files" : filter.title
    }

    private func row(_ file: FileHit, isSelected: Bool, isRecents: Bool) -> some View {
        DetailRow(
            icon: .file(path: file.path),
            title: file.name,
            subtitle: file.folder,
            trailing: isRecents ? file.lastOpened.map { ClipboardFormat.age(of: $0) } : nil,
            isSelected: isSelected
        )
        .id(file.id)
        .onTapGesture(count: 2) {
            browser.selectedID = file.id
            model.runPrimaryAction(on: file)
        }
        .simultaneousGesture(TapGesture().onEnded {
            browser.selectedID = file.id
        })
    }
}
