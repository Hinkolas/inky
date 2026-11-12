import AppKit
import Carbon.HIToolbox
import InkyCore
import SwiftUI

// MARK: - General

struct GeneralPane: View {
    @Bindable var preferences: Preferences
    let context: AppContext
    @State private var launchesAtLogin = false
    @State private var loginError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Inky hotkey")
                    Spacer()
                    // Inky always has one: recording replaces it, nothing takes it away.
                    HotkeyRecorder(
                        combo: Binding(
                            get: { preferences.hotkey },
                            set: { if let combo = $0 { preferences.hotkey = combo } }
                        ),
                        onRecordingChange: { preferences.isRecordingHotkey = $0 }
                    )
                }
            } header: {
                PaneHeader(
                    icon: .symbol("gearshape.fill", tint: .gray),
                    title: "General",
                    summary: "How Inky starts and how you open it."
                )
            } footer: {
                if !preferences.isHotkeyAvailable {
                    Text("macOS did not accept this shortcut. Choose a different one.")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Launch Inky at login", isOn: Binding(
                    get: { launchesAtLogin },
                    set: { enabled in
                        do {
                            try preferences.setLaunchesAtLogin(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                        launchesAtLogin = preferences.launchesAtLogin
                    }
                ))
                Toggle("Show Inky in the menu bar", isOn: $preferences.showMenuBarIcon)
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } footer: {
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                } else if !preferences.showMenuBarIcon {
                    Text("Without the menu bar icon, open settings by searching for “Inky Settings”.")
                }
            }

            Section {
                Toggle("Animate the launcher", isOn: $preferences.animations)
            } footer: {
                if preferences.animations, reduceMotion {
                    Text("Reduce Motion is on in System Settings, so the launcher fades instead of moving.")
                }
            }

            LauncherMemorySettings(preferences: preferences, history: context.inputHistory, usage: context.engine.usage)

            UpdateSettings(updates: context.updates)

            WebsiteIconSettings(preferences: preferences, context: context)
        }
        .onAppear { launchesAtLogin = preferences.launchesAtLogin }
    }
}

/// What the launcher keeps of what was in it: for opening it again where
/// it was left, and for ↑ to bring back.
private struct LauncherMemorySettings: View {
    @Bindable var preferences: Preferences
    let history: InputHistory
    let usage: UsageStore

    var body: some View {
        Section {
            Picker("Reopen where you left off", selection: $preferences.resumeWindow) {
                ForEach(ResumeWindow.allCases) { window in
                    Text(window.title).tag(window)
                }
            }
        } footer: {
            Text(preferences.resumeWindow == .off
                ? "The launcher opens empty every time."
                : "Clicking elsewhere or pressing the hotkey again puts the launcher away as it is: the search, what is selected, a command that is open. Escape and ⌘W close it for good.")
        }

        Section {
            Picker("Remember searches", selection: $preferences.historyLimit) {
                ForEach(Preferences.historyLimits, id: \.self) { limit in
                    Text(limit == 0 ? "None" : "The last \(limit)").tag(limit)
                }
            }
            if preferences.historyLimit > 0 {
                LabeledContent("Remembered") {
                    HStack(spacing: 10) {
                        Text(history.entries.count == 1 ? "1 search" : "\(history.entries.count) searches")
                            .monospacedDigit()
                        Button("Clear History") {
                            history.clear()
                            // The rankings remember searches too.
                            usage.forgetQueries()
                        }
                        .disabled(history.entries.isEmpty)
                    }
                }
            }
        } footer: {
            Text(preferences.historyLimit == 0
                ? "Nothing you type into the search is kept."
                : "↑ in the empty search brings back what you searched for before, newest first, with what you typed into a quicklink’s arguments. Everything stays on this Mac.")
        }
    }
}

/// Whether and how Inky keeps itself up to date.
private struct UpdateSettings: View {
    @Bindable var updates: Updates

    var body: some View {
        Section {
            if updates.isAvailable {
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                Toggle("Download and install updates automatically", isOn: $updates.installsAutomatically)
                    .disabled(!updates.checksAutomatically)
                Picker("Update channel", selection: $updates.channel) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                LabeledContent("Last checked") {
                    HStack(spacing: 10) {
                        Text(updates.lastCheck.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                        Button("Check Now") { updates.check() }
                            .disabled(!updates.canCheck)
                    }
                }
            } else {
                LabeledContent("Updates", value: "Not available in this build")
            }
        } footer: {
            if updates.isAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    if updates.channel == .beta {
                        Text("Beta also gets alpha, beta and release candidate versions, which can be unfinished. Going back to Stable keeps this version until a newer release comes out.")
                    }
                    Text("Inky asks GitHub for the list of its releases, and installs only updates signed by its developer. Nothing about you or your Mac is sent.")
                }
            } else {
                Text("Development builds, and builds made without the release signing key, do not update themselves.")
            }
        }
    }
}

/// Where website icons come from, and a way to fetch them all again.
private struct WebsiteIconSettings: View {
    @Bindable var preferences: Preferences
    let context: AppContext

    var body: some View {
        let favicons = context.favicons
        let refresh = favicons.refresh
        Section {
            Picker("Website icons", selection: $preferences.faviconSource) {
                ForEach(FaviconSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            if preferences.faviconSource != .off {
                LabeledContent("Saved icons") {
                    HStack(spacing: 10) {
                        if let refresh, refresh.isRunning {
                            ProgressView()
                                .controlSize(.small)
                            Text("\(refresh.completed) of \(refresh.total)")
                                .monospacedDigit()
                        } else {
                            Text("\(favicons.iconCount)")
                                .monospacedDigit()
                        }
                        Button("Refresh All") { context.refreshFavicons() }
                            .disabled(refresh?.isRunning == true)
                    }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                switch preferences.faviconSource {
                case .duckDuckGo:
                    Text("Inky asks DuckDuckGo for the icon of each website in your quicklinks. Only the domain name is sent, and the icon is kept for 30 days. Local addresses, such as localhost, are never sent.")
                case .off:
                    Text("Inky makes no requests for icons, and websites show the link tile.")
                }
                if preferences.faviconSource != .off, let refresh, !refresh.isRunning, refresh.failed > 0 {
                    Text(refresh.failed == 1
                        ? "1 website could not be asked about. What was saved for it is unchanged."
                        : "\(refresh.failed) websites could not be asked about. What was saved for them is unchanged.")
                }
            }
        }
    }
}

/// A button that captures the next key combination pressed.
struct HotkeyRecorder: View {
    enum Style {
        /// A button of its own, for a hotkey that is a setting.
        case button
        /// Part of a row in a list of commands, most of which have none.
        case inline
    }

    /// Nil while there is none.
    @Binding var combo: KeyCombo?
    var style = Style.button
    /// Says why a combination cannot be taken, or nil if it can.
    var refusal: (KeyCombo) -> String? = { _ in nil }
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Group {
            switch style {
            case .button: button
            case .inline: inline
            }
        }
        .onDisappear(perform: stop)
    }

    private var button: some View {
        Button {
            if isRecording { stop() } else { start() }
        } label: {
            Group {
                if isRecording {
                    Text("Press a shortcut…").foregroundStyle(.secondary)
                } else if let combo {
                    Keycap(combo.symbols)
                } else {
                    Text("Record Shortcut")
                }
            }
            .frame(minWidth: 120, minHeight: 22)
        }
        .help(isRecording ? "Press Escape to cancel" : "Click to record a new hotkey")
    }

    /// Where the hotkeys of a list line up.
    private static let inlineWidth: CGFloat = 132

    private var inline: some View {
        HStack(spacing: 4) {
            Button {
                if isRecording { stop() } else { start() }
            } label: {
                Group {
                    if isRecording {
                        Text("Press keys…")
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(
                                Color.accentColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            )
                    } else if let combo {
                        Keycap(combo.symbols)
                    } else {
                        Text("Add Hotkey").foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press Escape to cancel, or Delete to remove the hotkey" : combo == nil ? "Click to record a hotkey" : "Click to record a different hotkey")
            .accessibilityLabel(combo == nil ? "Add Hotkey" : "Hotkey")

            if combo != nil, !isRecording {
                Button("Remove Hotkey", systemImage: "xmark.circle.fill") { combo = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Remove the hotkey")
            }
        }
        .frame(width: Self.inlineWidth, alignment: .leading)
    }

    private func start() {
        isRecording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }
            let candidate = KeyCombo(event: event)
            // In a list, Delete on its own takes the hotkey away.
            if style == .inline, candidate.flags.isEmpty,
               [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
                if combo != nil { combo = nil }
                stop()
                return nil
            }
            // A hotkey needs a modifier other than Shift, or it would swallow typing.
            guard !candidate.flags.subtracting(.shift).isEmpty else {
                NSSound.beep()
                return nil
            }
            // Keys that something else has are refused, and it is said why.
            guard refusal(candidate) == nil else {
                NSSound.beep()
                stop()
                return nil
            }
            // Stop first: that re-registers the hotkey, and it must be the new one.
            combo = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        onRecordingChange(false)
    }
}

// MARK: - Fallback commands

/// Which commands the launcher offers to send a search to, and in what order.
struct FallbackPane: View {
    static let title = "Fallback Commands"
    static let icon = Icon.symbol("arrow.turn.down.right", tint: .orange)

    let engine: SearchEngine

    var body: some View {
        let store = engine.fallbackStore
        let chosen = engine.chosenFallbacks()
        let listed = chosen.map(\.id)
        let candidates = engine.fallbackCandidates()
        // What is left to choose, under the module it comes from.
        let remaining = candidates.compactMap { section -> ResultSection? in
            let items = section.items.filter { !listed.contains($0.id) }
            return items.isEmpty ? nil : ResultSection(title: section.title, items: items)
        }
        Form {
            Section {
                ForEach(Array(chosen.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 10) {
                        IconView(icon: item.icon, size: 20)
                        Text(item.title)
                        Text(item.kind)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Move Up", systemImage: "chevron.up") {
                            store.move(item.id, by: -1, among: listed)
                        }
                        .disabled(index == 0)
                        .help("Offer \(item.title) earlier")
                        Button("Move Down", systemImage: "chevron.down") {
                            store.move(item.id, by: 1, among: listed)
                        }
                        .disabled(index == chosen.count - 1)
                        .help("Offer \(item.title) later")
                        Button("Remove", systemImage: "minus") {
                            store.remove(item.id)
                        }
                        .help("Stop offering \(item.title)")
                    }
                    .labelStyle(.iconOnly)
                }
                if candidates.isEmpty {
                    Text("No command asks for exactly one argument yet. A quicklink with one does.")
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(remaining) { section in
                            Section(section.title) {
                                ForEach(section.items) { item in
                                    Button(item.title) { store.add(item.id) }
                                }
                            }
                        }
                    } label: {
                        Label("Add Fallback Command", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(remaining.isEmpty)
                }
            } header: {
                PaneHeader(
                    icon: Self.icon,
                    title: Self.title,
                    summary: "Send what you typed somewhere else, such as the web."
                )
            } footer: {
                Text("Listed below the results of every search, with what you typed as their argument. When nothing was found, Return runs the first one. Any command that asks for exactly one argument can be a fallback, such as a quicklink with one.")
            }
        }
    }
}

// MARK: - About

struct AboutPane: View {
    let showWelcome: () -> Void
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    private let repository = URL(string: "https://github.com/Hinkolas/inky")!

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Source code") {
                    Link("github.com/Hinkolas/inky", destination: repository)
                }
                LabeledContent("Welcome") {
                    Button("Show Welcome Window", action: showWelcome)
                }
            } header: {
                PaneHeader(
                    icon: .inky,
                    title: "Inky",
                    summary: "A fast, open source launcher for macOS."
                )
            }
        }
    }
}

// MARK: - Extensions

struct ModulePane: View {
    let module: any Module
    let context: AppContext

    var body: some View {
        let preferences = context.preferences
        Form {
            Section {
                Toggle("Enable \(module.info.title)", isOn: Binding(
                    get: { preferences.isEnabled(module.id) },
                    set: { preferences.setEnabled(module.id, $0) }
                ))
            } header: {
                PaneHeader(icon: module.info.icon, title: module.info.title, summary: module.info.summary)
            } footer: {
                if module.id == "clipboard", !preferences.isEnabled(module.id) {
                    Text("While this is off, nothing you copy is kept. What is already in the history stays as it is.")
                }
            }

            switch module.id {
            case "applications":
                Section("Searched folders") {
                    ForEach(ApplicationScanner.searchPaths, id: \.self) { path in
                        Text(path).font(.system(.body, design: .monospaced))
                    }
                }
            case "calculator":
                Examples([
                    "128 * 3 + 4", "20% off 80", "sqrt(2) ^ 10", "5 ft 10 in in cm", "72 F to C",
                    "100 usd in eur", "255 in hex", "2rem in px",
                ])
                ExchangeRateSettings(preferences: preferences, store: context.exchangeRates)
                WebUnitSettings(preferences: preferences)
            case "time":
                Examples([
                    "time in tokyo", "5pm london in berlin", "time diff san francisco",
                    "monday in 3 weeks", "days until 24 dec",
                ])
            case "color":
                Examples([
                    "#ff6363", "rgb(255, 99, 99)", "oklch(0.7 0.19 23)", "rgb(255 99 99 / 50%)",
                    "#fa32fa in rgb", "rgb(255, 0, 0) to hsl",
                ])
            case "browser":
                Examples([
                    "amazon.com", "github.com/hinkolas/inky", "localhost:3000", "https://example.com/page?id=1",
                ])
            case "files":
                FileSearchSettings(context: context)
            case "quicklinks":
                QuicklinkSettings(context: context)
            case "clipboard":
                ClipboardSettings(preferences: preferences, history: context.clipboard)
            default:
                EmptyView()
            }

            // The quicklinks are listed above, with what else is done to one.
            if module.id != "quicklinks" {
                ModuleCommands(module: module, context: context)
            }
        }
    }
}

/// A few things to type, to show what a module understands.
private struct Examples: View {
    let examples: [String]

    init(_ examples: [String]) {
        self.examples = examples
    }

    var body: some View {
        Section("Examples") {
            ForEach(examples, id: \.self) { example in
                Text(example).font(.system(.body, design: .monospaced))
            }
        }
    }
}

/// Where exchange rates come from, and a way to fetch them now.
private struct ExchangeRateSettings: View {
    @Bindable var preferences: Preferences
    let store: ExchangeRateStore

    /// The day of the rates is one in Greenwich, wherever it is read.
    private static let dayStyle: Date.FormatStyle = {
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = .gmt
        return style
    }()

    var body: some View {
        Section {
            Picker("Exchange rates", selection: $preferences.exchangeRateSource) {
                ForEach(ExchangeRateSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            if preferences.exchangeRateSource != .off {
                LabeledContent("Rates of") {
                    HStack(spacing: 10) {
                        if store.isUpdating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(store.rates?.day.formatted(Self.dayStyle) ?? "None yet")
                        Button("Update Now") { store.refresh() }
                            .disabled(store.isUpdating)
                    }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                switch preferences.exchangeRateSource {
                case .ecb:
                    Text("Inky downloads the reference rates of the European Central Bank: one file with about thirty currencies, a few times a day while you use the calculator. Nothing about you or what you type is sent. The bank sets its rates on working days.")
                case .off:
                    Text("Inky makes no requests for rates, and does not convert currencies.")
                }
                if preferences.exchangeRateSource != .off, store.failed, !store.isUpdating {
                    Text(store.rates == nil
                        ? "The rates could not be fetched. Inky tries again in a few minutes."
                        : "Newer rates could not be fetched. The ones above stay in use.")
                }
            }
        }
    }
}

/// How large a rem is, for the units of a web page.
private struct WebUnitSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Section {
            Stepper(
                "1 rem is \(preferences.pixelsPerRem) px",
                value: $preferences.pixelsPerRem,
                in: Preferences.pixelsPerRemRange
            )
        } footer: {
            Text("For the units of a web page, as in “2rem in px”. An em is taken to be as large as a rem.")
        }
    }
}

private struct FileSearchSettings: View {
    let context: AppContext

    var body: some View {
        @Bindable var preferences = context.preferences
        Section {
            Stepper(
                "Show up to \(preferences.fileSearchLimit) files",
                value: Binding(
                    get: { preferences.fileSearchLimit },
                    set: {
                        preferences.fileSearchLimit = $0
                        context.fileModule.maxResults = $0
                    }
                ),
                in: 3...20
            )
        } footer: {
            Text("Searches your home folder once you have typed three characters. Results come from the Spotlight index, so folders excluded from Spotlight do not appear.")
        }
    }
}

/// How long the clipboard history keeps what is copied, what Return does
/// in it, and how much it holds.
private struct ClipboardSettings: View {
    @Bindable var preferences: Preferences
    let history: ClipboardHistory
    @State private var statistics: ClipboardStatistics?
    @State private var canPressKeys = KeyboardPaste.isAllowed

    var body: some View {
        let isOn = preferences.isEnabled("clipboard")

        if !history.store.isPersistent {
            Section {
                Label("History is temporary", systemImage: "exclamationmark.triangle")
            } footer: {
                Text(ClipDescription.storageNotice)
            }
        }

        if isOn, history.access != .allowed {
            Section {
                LabeledContent {
                    Button("Open Privacy Settings") { ClipDescription.openPasteSettings() }
                } label: {
                    Label("Inky cannot read what you copy", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            } footer: {
                Text(ClipDescription.notice(for: history.access) + " The change applies once Inky is opened again.")
            }
        }

        Section {
            Picker("Keep history for", selection: $preferences.clipboardRetention) {
                ForEach(ClipboardRetention.allCases) { retention in
                    Text(retention.title).tag(retention)
                }
            }
            LabeledContent("In the history") {
                HStack(spacing: 10) {
                    Text(summary)
                        .monospacedDigit()
                    Button("Clear History…") { clear() }
                        .disabled((statistics?.entries ?? 0) - (statistics?.pinned ?? 0) <= 0)
                }
            }
        } footer: {
            Text(preferences.clipboardRetention == .forever
                ? "Nothing is removed until you delete it. Everything stays on this Mac."
                : "Items you have not copied again for that long are removed. Pinned items stay until you unpin or delete them. Everything stays on this Mac.")
        }

        Section {
            Toggle("Keep passwords from password managers", isOn: $preferences.clipboardKeepsConcealed)
        } footer: {
            Text(preferences.clipboardKeepsConcealed
                ? "What password managers mark as confidential is kept like any other copy, without encryption."
                : "What password managers mark as confidential is left out. A password copied from somewhere else cannot be told apart, and is kept.")
        }

        Section {
            Picker("Return", selection: $preferences.clipboardPastes) {
                Text("Pastes into the active app").tag(true)
                Text("Copies to the clipboard").tag(false)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(preferences.clipboardPastes
                    ? "⌘C copies an item without pasting it."
                    : "⌘↵ pastes an item into the app you were in.")
                if !canPressKeys {
                    HStack(spacing: 6) {
                        Text("To paste for you, Inky needs Accessibility access. Until then it copies, and you paste.")
                        Button("Open Accessibility Settings") { ClipDescription.openAccessibilitySettings() }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .task(id: history.revision) {
            statistics = await history.store.statistics()
        }
        .onAppear {
            history.refreshAccess()
            canPressKeys = KeyboardPaste.isAllowed
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings, perhaps with something changed.
            history.refreshAccess()
            canPressKeys = KeyboardPaste.isAllowed
        }
    }

    private var summary: String {
        guard let statistics else { return " " }
        let items = statistics.entries == 1 ? "1 item" : "\(statistics.entries.formatted()) items"
        return "\(items) · \(ByteCountFormatter.string(fromByteCount: statistics.bytes, countStyle: .file))"
    }

    private func clear() {
        let pinned = statistics?.pinned ?? 0
        guard Alerts.confirm(
            title: "Clear the clipboard history?",
            message: pinned == 0
                ? "Everything Inky kept of what you copied is deleted."
                : "Everything Inky kept of what you copied is deleted. What you pinned stays.",
            confirmTitle: "Clear History"
        ) else { return }
        Task { await history.clear() }
    }
}

/// The quicklinks, each a command with a hotkey and a box to switch it off,
/// and a menu to edit or delete it.
private struct QuicklinkSettings: View {
    let context: AppContext
    @State private var draft: QuicklinkDraft?

    var body: some View {
        let store = context.quicklinks
        let isModuleEnabled = context.preferences.isEnabled("quicklinks")
        Section {
            if store.quicklinks.isEmpty {
                Text("No quicklinks yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.quicklinks) { quicklink in
                CommandRow(
                    id: quicklink.itemID,
                    title: quicklink.name,
                    subtitle: quicklink.link,
                    icon: QuicklinkModule.icon(for: quicklink.template),
                    context: context,
                    isModuleEnabled: isModuleEnabled
                ) {
                    Menu {
                        Button("Edit…") { draft = QuicklinkDraft(quicklink) }
                        Button("Delete", role: .destructive) { delete(quicklink) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Edit or delete \(quicklink.name)")
                }
            }
        } header: {
            HStack {
                Text("Your quicklinks")
                Spacer()
                Button("New Quicklink", systemImage: "plus") { draft = QuicklinkDraft() }
                    .controlSize(.small)
            }
        } footer: {
            Text("A quicklink that is switched off is not found or suggested. A hotkey opens a quicklink from anywhere; one that asks for arguments shows Inky to take them.")
        }
        .sheet(item: $draft) { draft in
            QuicklinkSheet(draft: draft) { store.save(draft.quicklink) }
        }
    }

    /// With the quicklink goes what was remembered and decided about it.
    private func delete(_ quicklink: Quicklink) {
        context.quicklinks.delete(quicklink.id)
        context.engine.usage.forget(quicklink.itemID)
        context.engine.commandStore.forget(quicklink.itemID)
    }
}

private struct QuicklinkSheet: View {
    let draft: QuicklinkDraft
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(draft.isNew ? "New Quicklink" : "Edit Quicklink")
                .font(.headline)
            QuicklinkForm(draft: draft)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
