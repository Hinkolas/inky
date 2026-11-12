import AppKit
import InkyCore
import Observation
import SwiftUI

/// The state of the clipboard history's screen: what is asked for, what of
/// it has been read so far, and what is selected.
///
/// The history can be long. It is read a page at a time, as the selection
/// or the scrolling nears the end of what is there, and an entry's content
/// only once it is selected.
@Observable
final class ClipboardBrowser {
    /// A section title or an entry, in the order they are listed.
    enum Line: Identifiable {
        case header(String)
        case clip(Clip)

        var id: String {
            switch self {
            case .header(let title): "section.\(title)"
            case .clip(let clip): "clip.\(clip.id)"
            }
        }
    }

    @ObservationIgnored let history: ClipboardHistory

    var query = "" {
        didSet { if query != oldValue { reload() } }
    }

    var filter = ClipFilter.all {
        didSet { if filter != oldValue { reload() } }
    }

    var range = ClipRange.all {
        didSet { if range != oldValue { reload() } }
    }

    var selectedID: Int64? {
        didSet { if selectedID != oldValue { loadContent() } }
    }

    /// The pins, and how many entries there are of each kind.
    private(set) var snapshot = ClipSnapshot()
    /// What the arrow keys go through: the pinned entries that are asked
    /// for, then the rest as far as it has been read.
    private(set) var clips: [Clip] = []
    /// What the list shows.
    private(set) var lines: [Line] = []
    /// Whether the list shows the pinned entries too. With nothing asked
    /// for they are all in the sidebar, and the list begins with the latest
    /// copy; once something is, the ones it finds lead the list.
    private(set) var listsPins = false
    /// False until the history was read for the first time.
    private(set) var isLoaded = false
    /// What the selected entry holds, once it is read.
    private(set) var content: ClipContent?
    /// The name being typed for the selected entry, while it is renamed.
    var renaming: String?

    @ObservationIgnored private var asked = ClipQuery()
    @ObservationIgnored private var unpinned: [Clip] = []
    @ObservationIgnored private var hasMore = false
    @ObservationIgnored private var isReadingMore = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var contentGeneration = 0

    private static let pageSize = 150
    /// How close to the end of what is read the next page is asked for.
    private static let readAhead = 40

    init(history: ClipboardHistory) {
        self.history = history
        reload()
    }

    /// Reads the history again, as when what is asked for changed or
    /// something was copied.
    func reload() {
        generation += 1
        let generation = generation
        let query = ClipQuery(text: query, filter: filter, since: range.start())
        // As many as were there, so that the list does not end under the
        // selection because something was copied meanwhile.
        let limit = query.text == asked.text && query.filter == asked.filter
            ? max(Self.pageSize, unpinned.count) : Self.pageSize
        Task {
            let snapshot = await history.store.snapshot(query, limit: limit)
            guard generation == self.generation else { return }
            asked = query
            self.snapshot = snapshot
            unpinned = snapshot.clips
            hasMore = snapshot.hasMore
            isLoaded = true
            list()
        }
    }

    private func readMore() {
        guard hasMore, !isReadingMore, let last = unpinned.last else { return }
        isReadingMore = true
        let generation = generation
        Task {
            let page = await history.store.page(asked, after: last, limit: Self.pageSize)
            isReadingMore = false
            // What it was read for has been asked differently since.
            guard generation == self.generation else { return }
            unpinned += page.clips
            hasMore = page.hasMore
            list()
        }
    }

    private func list() {
        let sections = ClipSections()
        var lines: [Line] = []
        listsPins = !(asked.text.allSatisfy(\.isWhitespace) && asked.filter == .all)
        if listsPins, !snapshot.pinned.isEmpty {
            lines.append(.header("Pinned"))
            lines += snapshot.pinned.map(Line.clip)
        }
        var title: String?
        for clip in unpinned {
            let section = sections.title(of: clip.lastCopied)
            if section != title {
                title = section
                lines.append(.header(section))
            }
            lines.append(.clip(clip))
        }
        clips = snapshot.pinned + unpinned
        self.lines = lines
        loadContent()
    }

    // MARK: - Selection

    /// The selected entry. Until one is chosen that is the first in the
    /// list: the latest copy, or what a search found first.
    var selected: Clip? {
        clips.first { $0.id == selectedID } ?? (listsPins ? nil : unpinned.first) ?? clips.first
    }

    /// Up from the latest copy leads to what is pinned.
    func moveSelection(by offset: Int) {
        guard let selected, let current = clips.firstIndex(where: { $0.id == selected.id }) else { return }
        let next = min(max(current + offset, 0), clips.count - 1)
        selectedID = clips[next].id
        if next >= clips.count - Self.readAhead { readMore() }
    }

    /// Called when the row of `clip` is drawn: near the end, there is more to read.
    func didShow(_ clip: Clip) {
        guard hasMore, let index = unpinned.lastIndex(where: { $0.id == clip.id }),
              index >= unpinned.count - Self.readAhead
        else { return }
        readMore()
    }

    func cycleFilter(by offset: Int) {
        let filters = ClipFilter.allCases
        let current = filters.firstIndex(of: filter) ?? 0
        filter = filters[(current + offset + filters.count) % filters.count]
    }

    /// Moves the selection off an entry that is about to go away.
    func selectNeighbor(of id: Int64) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let neighbor = index + 1 < clips.count ? index + 1 : index - 1
        selectedID = clips.indices.contains(neighbor) ? clips[neighbor].id : nil
    }

    /// Selects a pinned entry, and lists it if what is asked for leaves it out.
    func show(_ pin: Clip) {
        if !clips.contains(where: { $0.id == pin.id }) {
            query = ""
            filter = .all
        }
        selectedID = pin.id
    }

    private func loadContent() {
        guard let clip = selected, clip.kind != .image else {
            content = nil
            return
        }
        guard content?.id != clip.id else { return }
        contentGeneration += 1
        let generation = contentGeneration
        Task {
            let content = await history.store.content(of: clip.id)
            if generation == contentGeneration { self.content = content }
        }
    }

    // MARK: - Renaming

    func beginRenaming() {
        guard let clip = selected, clip.isPinned else { return }
        selectedID = clip.id
        renaming = clip.name ?? ""
    }

    func commitRenaming() {
        guard let name = renaming, let clip = selected else { return }
        renaming = nil
        Task { await history.rename(clip, to: name) }
    }
}

// MARK: - Screen

/// The clipboard history: a sidebar to narrow it down and reach what is
/// pinned, the list, and a side panel with the selected entry and what can
/// be done with it.
struct ClipboardBrowserScreen: View {
    let model: LauncherModel
    @Bindable var browser: ClipboardBrowser
    let focus: LauncherFocus

    /// Of the body card.
    static let size = CGSize(width: 940, height: 500)

    private static let top = "inky.clips.top"
    private static let end = "inky.clips.end"

    var body: some View {
        let selected = browser.selected
        let total = browser.snapshot.total

        CommandScreen(
            icon: ClipboardModule.icon,
            path: [ClipboardModule.title],
            size: Self.size
        ) {
            FilterField(
                text: $browser.query,
                prompt: total == 1 ? "Filter 1 item" : "Filter \(total) items",
                focus: focus
            )
        } accessory: {
            rangeMenu
        } content: {
            HStack(spacing: 0) {
                Sidebar { sidebar(selected) }

                VStack(spacing: 0) {
                    if !browser.history.store.isPersistent {
                        Label(ClipDescription.storageNotice, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    }
                    if browser.history.access != .allowed {
                        AccessNotice(access: browser.history.access, dismiss: model.dismiss)
                    }
                    list(selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                SidePanel(width: 280) {
                    if let selected {
                        inspector(selected)
                    }
                }
            }
        }
        .onAppear { browser.history.refreshAccess() }
        .onChange(of: browser.history.revision) { browser.reload() }
        // The name is typed where it is shown, and the filter is typed into
        // again once the name is saved or let be.
        .onChange(of: browser.renaming != nil) { model.focusDefault() }
    }

    private var rangeMenu: some View {
        Menu {
            Picker("Copied", selection: $browser.range) {
                ForEach(ClipRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 7) {
                Text(browser.range.title)
                    .font(.system(size: 13.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: LauncherMetrics.barControlSize)
            .background(Theme.controlFill, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.controlStroke) }
            .shadow(color: Theme.controlShadow, radius: 3, y: 1)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show only what was copied lately")
    }

    // MARK: - Sidebar

    @ViewBuilder private func sidebar(_ selected: Clip?) -> some View {
        PanelLabel("Type")
            .padding(.horizontal, 9)
            .padding(.top, 7)
            .padding(.bottom, 9)
        ForEach(ClipFilter.allCases, id: \.self) { filter in
            SidebarRow(
                title: filter.title,
                symbol: filter.symbol,
                count: browser.snapshot.count(filter),
                isSelected: filter == browser.filter
            ) {
                browser.filter = filter
            }
        }

        let pins = browser.snapshot.pins
        if !pins.isEmpty {
            PanelLabel("Pinned")
                .padding(.horizontal, 9)
                .padding(.top, 18)
                .padding(.bottom, 9)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(pins) { pin in
                            PinRow(
                                clip: pin,
                                isSelected: pin.id == selected?.id,
                                // Selected here, unless the list shows it as well.
                                isProminent: !browser.listsPins
                            ) {
                                browser.show(pin)
                            }
                            .id(pin.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: selected?.id) { _, id in
                    if let id, pins.contains(where: { $0.id == id }) { proxy.scrollTo(id) }
                }
            }
        }
    }

    // MARK: - List

    @ViewBuilder private func list(_ selected: Clip?) -> some View {
        if browser.clips.isEmpty {
            // Empty for a moment while the history is read, too.
            if browser.isLoaded {
                let isEmpty = browser.snapshot.total == 0 && browser.range == .all
                VStack(spacing: 6) {
                    Text(isEmpty ? "Nothing copied yet" : "No matching items")
                        .font(.system(size: 14, weight: .medium))
                    if isEmpty {
                        Text("What you copy from now on is kept here.")
                            .font(.system(size: 12.5))
                    }
                }
                .foregroundStyle(.secondary)
            }
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
                            case .clip(let clip):
                                row(clip, isSelected: clip.id == selected?.id)
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
                    let listed = browser.lines.compactMap { line in
                        if case .clip(let clip) = line { clip.id } else { nil }
                    }
                    if listed.contains(id) {
                        proxy.reveal(id, after: previous, among: listed, top: Self.top, end: Self.end)
                    } else {
                        // Selected in the sidebar: the list is at its beginning.
                        proxy.scrollTo(Self.top, anchor: .top)
                    }
                }
            }
        }
    }

    private func row(_ clip: Clip, isSelected: Bool) -> some View {
        DetailRow(
            title: clip.displayTitle,
            subtitle: ClipDescription.subtitle(of: clip),
            trailing: clip.isPinned ? nil : ClipboardFormat.age(of: clip.lastCopied),
            isSelected: isSelected,
            isMonospaced: clip.name == nil && (clip.kind == .path || clip.kind == .color)
        ) {
            ClipIcon(clip: clip, store: browser.history.store, isSelected: isSelected)
        }
        .id(clip.id)
        .onAppear { browser.didShow(clip) }
        .onTapGesture(count: 2) {
            browser.selectedID = clip.id
            model.runPrimaryAction(on: clip, in: browser)
        }
        .simultaneousGesture(TapGesture().onEnded {
            browser.selectedID = clip.id
        })
    }

    // MARK: - Inspector

    @ViewBuilder private func inspector(_ clip: Clip) -> some View {
        if browser.renaming != nil {
            PanelLabel("Name")
                .padding(.horizontal, 2)
                .padding(.bottom, 7)
            TextField(clip.title, text: Binding(
                get: { browser.renaming ?? "" },
                // A field that is on its way out hands in what it held once
                // more. That must not begin the renaming again.
                set: { if browser.renaming != nil { browser.renaming = $0 } }
            ))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .launcherFocus(focus, .clipName)
                .modifier(FieldBox(isFocused: focus.wrappedValue == .clipName))
                .padding(.bottom, 14)
        }

        ClipPreview(clip: clip, content: browser.content?.id == clip.id ? browser.content : nil, store: browser.history.store)
            // Takes the room the rest leaves, and no more than it fills.
            .layoutPriority(-1)

        MetadataList(rows: ClipDescription.facts(about: clip, content: browser.content?.id == clip.id ? browser.content : nil))
            .padding(.top, 14)
            .padding(.horizontal, 2)
            .fixedSize(horizontal: false, vertical: true)

        PanelDivider()
            .padding(.vertical, 14)

        if browser.renaming != nil {
            HStack(spacing: 16) {
                KeyHint(["↵"], title: "Save")
                KeyHint(["esc"], title: "Cancel")
            }
            .padding(.horizontal, 2)
        } else {
            ActionList(actions: model.actions(for: clip, in: browser))
                .padding(.horizontal, -4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Parts

/// A pinned entry in the sidebar: a dot and what it is called.
private struct PinRow: View {
    let clip: Clip
    let isSelected: Bool
    /// Whether being selected shows as it does in the list.
    let isProminent: Bool
    let action: () -> Void

    /// Told apart by color. Which one an entry gets stays the same.
    private static let colors: [Color] = [.orange, .purple, .green, .blue, .pink, .teal]

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(color)
                    .overlay {
                        if isSelected, isProminent { Circle().strokeBorder(.white.opacity(0.7)) }
                    }
                    .frame(width: 8, height: 8)
                    .frame(width: 18)
                Text(clip.displayTitle)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected && isProminent ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .frame(height: 33)
            .background(
                !isSelected ? AnyShapeStyle(.clear) : isProminent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.subtleFill),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 1))
        .help(clip.title)
    }

    private var color: Color {
        // A color that is pinned is its own.
        if clip.kind == .color, let color = ColorValue(clip.title)?.displayed {
            return Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
        }
        return Self.colors[Int(clip.id % Int64(Self.colors.count))]
    }
}

/// What stands in front of an entry: a color, a small copy of an image, a
/// file's icon, or a sign of the kind it is.
struct ClipIcon: View {
    let clip: Clip
    let store: ClipboardStore
    var isSelected = false
    var size: CGFloat = 30

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        switch clip.kind {
        case .color:
            if let color = ColorValue(clip.title)?.displayed {
                IconView(
                    icon: .swatch(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha),
                    size: size, outline: isSelected ? 0.5 : 0
                )
            } else {
                symbol(tile)
            }
        case .image:
            // The preview, which takes many times as long to show, only
            // where there is no thumbnail.
            if let image = store.thumbnailURL(of: clip).flatMap(ClipImages.shared.image(at:))
                ?? store.previewURL(of: clip).flatMap(ClipImages.shared.image(at:)) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(tile)
                    .overlay { tile.strokeBorder(isSelected ? Color.white.opacity(0.5) : Color.primary.opacity(0.14)) }
            } else {
                symbol(tile)
            }
        case .file, .path:
            if let path = clip.location {
                IconView(icon: .file(path: path), size: size)
            } else {
                symbol(tile)
            }
        case .text, .link:
            symbol(tile)
        }
    }

    private func symbol(_ tile: RoundedRectangle) -> some View {
        tile
            .fill(isSelected ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(Theme.controlFill))
            .overlay {
                if !isSelected { tile.strokeBorder(Theme.controlStroke) }
            }
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: clip.kind.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary.opacity(0.75)))
            }
    }
}

/// The small copies of images that have been shown, kept while there is room.
final class ClipImages {
    static let shared = ClipImages()

    private let cache = NSCache<NSURL, NSImage>()

    func image(at url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// The selected entry, as much of it as there is room for.
private struct ClipPreview: View {
    let clip: Clip
    let content: ClipContent?
    let store: ClipboardStore

    /// More than fits. A long text is laid out whole before it is cut off.
    private static let shownCharacters = 1500

    var body: some View {
        switch clip.kind {
        case .image:
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            Group {
                if let image = store.previewURL(of: clip).flatMap(ClipImages.shared.image(at:)) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 170)
            .background(Theme.fieldFill, in: shape)
            .overlay { shape.strokeBorder(Theme.fieldStroke) }
        case .color:
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            if let color = ColorValue(clip.title)?.displayed {
                shape
                    .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                    .frame(height: 76)
                    .overlay { shape.strokeBorder(Color.primary.opacity(0.14)) }
            }
            PreviewBox(text: clip.title)
                .lineLimit(2)
                .padding(.top, 8)
        case .file:
            let paths = (content?.text ?? clip.location ?? clip.title).split(separator: "\n")
            PreviewBox(
                text: paths.prefix(12).map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"),
                fontSize: 10.5
            )
        case .text, .path, .link:
            // A path or a link is small enough for a line of it to fit.
            PreviewBox(
                text: String((content?.text ?? clip.title).prefix(Self.shownCharacters)),
                isMonospaced: clip.kind != .text,
                fontSize: clip.kind == .text ? 12.5 : 10.5
            )
        }
    }
}

/// Says that macOS keeps Inky from reading what is copied, and where to change that.
private struct AccessNotice: View {
    let access: ClipboardHistory.Access
    let dismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
            Text(ClipDescription.notice(for: access))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                ClipDescription.openPasteSettings()
                dismiss()
            } label: {
                Text("Open Settings")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Theme.controlFill, in: Capsule())
                    .overlay { Capsule().strokeBorder(Theme.controlStroke) }
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .background(Theme.panelFill, in: shape)
        .overlay { shape.strokeBorder(Theme.panelStroke) }
        .padding(.horizontal, 2)
        .padding(.top, LauncherMetrics.panelInset)
    }
}

// MARK: - Wording

/// How an entry of the clipboard history is put into words.
enum ClipDescription {
    /// The line below an entry's title: its kind, and what tells it from
    /// others of that kind.
    static func subtitle(of clip: Clip) -> String {
        let kind = switch clip.kind {
        case .file where clip.items > 1: "\(clip.items) Files"
        case .image: imageFormat(of: clip)
        default: clip.kind.title
        }
        // Under a name, what it holds.
        if clip.name?.isEmpty == false { return "\(kind) · \(clip.title)" }

        let detail: String? = switch clip.kind {
        case .image: dimensions(of: clip)
        case .color: ColorValue(clip.title).flatMap { ColorValue.Format(rawValue: $0.notation.rawValue)?.title }
        case .file: clip.location.map { (($0 as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
        case .text, .path, .link: clip.sourceName
        }
        return detail.map { "\(kind) · \($0)" } ?? kind
    }

    private static func imageFormat(of clip: Clip) -> String {
        let format = clip.location.map { ($0 as NSString).pathExtension.uppercased() } ?? ""
        return format.isEmpty ? "Image" : format
    }

    private static func dimensions(of clip: Clip) -> String? {
        guard let width = clip.width, let height = clip.height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    /// What the side panel says about an entry.
    static func facts(about clip: Clip, content: ClipContent?) -> [(name: String, value: String)] {
        var facts: [(name: String, value: String)] = [
            ("Source", clip.sourceName ?? "Unknown"),
            ("Copied", copied.string(from: clip.lastCopied)),
        ]
        if clip.copies > 1 {
            facts.append(("Times", "\(clip.copies)"))
        }
        switch clip.kind {
        case .image:
            if let dimensions = dimensions(of: clip) { facts.append(("Pixels", dimensions)) }
            facts.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(clip.byteCount), countStyle: .file)))
        case .color:
            if let color = ColorValue(clip.title) {
                for format in [ColorValue.Format.hex, .rgb, .hsl] where format.rawValue != color.notation.rawValue {
                    facts.append((format.title, color.text(as: format)))
                }
            }
        case .file:
            if let path = clip.location, !FileManager.default.fileExists(atPath: path) {
                facts.append(("Status", clip.items == 1 ? "No longer there" : "Not all there anymore"))
            }
        case .text, .path, .link:
            // A space until it is read, so that nothing moves when it is.
            facts.append(("Size", content.map(size(of:)) ?? " "))
        }
        return facts
    }

    private static func size(of content: ClipContent) -> String {
        let characters = content.characters == 1 ? "1 character" : "\(content.characters.formatted()) characters"
        return content.lines > 1 ? "\(content.lines.formatted()) lines · \(characters)" : characters
    }

    /// "Today at 14:31", and a date for what is older than yesterday.
    private static let copied: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static let storageNotice = "The saved history could not be opened. New copies are kept only until Inky quits. Your saved files have been left in place. Try reopening Inky. If this continues, report the problem using the repository linked in Settings → About."

    static func notice(for access: ClipboardHistory.Access) -> String {
        switch access {
        case .allowed: ""
        case .asks: "macOS asks each time Inky reads what you copied, so nothing new is kept. Allow Inky under Privacy & Security → Paste from Other Apps."
        case .denied: "macOS does not let Inky read what you copy, so nothing new is kept. Allow Inky under Privacy & Security → Paste from Other Apps."
        }
    }

    /// Opens the part of System Settings that decides who may read the pasteboard.
    static func openPasteSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
