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
                    HotkeyRecorder(combo: $preferences.hotkey) { isRecording in
                        preferences.isRecordingHotkey = isRecording
                    }
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

            WebsiteIconSettings(preferences: preferences, context: context)
        }
        .onAppear { launchesAtLogin = preferences.launchesAtLogin }
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
    @Binding var combo: KeyCombo
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording { stop() } else { start() }
        } label: {
            Group {
                if isRecording {
                    Text("Press a shortcut…").foregroundStyle(.secondary)
                } else {
                    Keycap(combo.symbols)
                }
            }
            .frame(minWidth: 120, minHeight: 22)
        }
        .help(isRecording ? "Press Escape to cancel" : "Click to record a new hotkey")
        .onDisappear(perform: stop)
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
            // A hotkey needs a modifier other than Shift, or it would swallow typing.
            guard !candidate.flags.subtracting(.shift).isEmpty else {
                NSSound.beep()
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

// MARK: - About

struct AboutPane: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    private let repository = URL(string: "https://github.com/Hinkolas/inky")!

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Source code") {
                    Link("github.com/Hinkolas/inky", destination: repository)
                }
            } header: {
                PaneHeader(
                    icon: .symbol("drop.fill", tint: .indigo),
                    title: "Inky",
                    summary: "A fast, open source launcher for macOS."
                )
            }
        }
    }
}

// MARK: - Extensions

struct ProviderPane: View {
    let provider: any Provider
    let context: AppContext

    var body: some View {
        let preferences = context.preferences
        Form {
            Section {
                Toggle("Enable \(provider.info.title)", isOn: Binding(
                    get: { preferences.isEnabled(provider.id) },
                    set: { preferences.setEnabled(provider.id, $0) }
                ))
            } header: {
                PaneHeader(icon: provider.info.icon, title: provider.info.title, summary: provider.info.summary)
            }

            switch provider.id {
            case "applications":
                Section("Searched folders") {
                    ForEach(ApplicationScanner.searchPaths, id: \.self) { path in
                        Text(path).font(.system(.body, design: .monospaced))
                    }
                }
            case "calculator":
                Examples([
                    "128 * 3 + 4", "20% off 80", "sqrt(2) ^ 10", "5 ft 10 in in cm", "72 F to C",
                    "100 usd in eur", "255 in hex",
                ])
                ExchangeRateSettings(preferences: preferences, store: context.exchangeRates)
            case "time":
                Examples([
                    "time in tokyo", "5pm london in berlin", "time diff san francisco",
                    "monday in 3 weeks", "days until 24 dec",
                ])
            case "files":
                FileSearchSettings(context: context)
            case "quicklinks":
                QuicklinkSettings(store: context.quicklinks)
                FallbackSettings(store: context.quicklinks)
            default:
                EmptyView()
            }
        }
    }
}

/// A few things to type, to show what a provider understands.
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
                        context.fileProvider.maxResults = $0
                    }
                ),
                in: 3...20
            )
        } footer: {
            Text("Searches your home folder once you have typed three characters. Results come from the Spotlight index, so folders excluded from Spotlight do not appear.")
        }
    }
}

private struct QuicklinkSettings: View {
    let store: QuicklinkStore
    @State private var draft: QuicklinkDraft?

    var body: some View {
        Section {
            if store.quicklinks.isEmpty {
                Text("No quicklinks yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.quicklinks) { quicklink in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quicklink.name)
                        Text(quicklink.link)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Edit") { draft = QuicklinkDraft(quicklink) }
                    Button("Delete", systemImage: "trash", role: .destructive) { store.delete(quicklink.id) }
                        .labelStyle(.iconOnly)
                        .help("Delete \(quicklink.name)")
                }
            }
        } header: {
            HStack {
                Text("Your quicklinks")
                Spacer()
                Button("New Quicklink", systemImage: "plus") { draft = QuicklinkDraft() }
                    .controlSize(.small)
            }
        }
        .sheet(item: $draft) { draft in
            QuicklinkSheet(draft: draft) { store.save(draft.quicklink) }
        }
    }
}

/// Which quicklinks the launcher offers to send a search to, and in what order.
private struct FallbackSettings: View {
    let store: QuicklinkStore

    /// The same quicklinks are rows of the section above. A form tells its
    /// rows apart by id across sections, so these need ids of their own.
    private struct Row: Identifiable {
        let index: Int
        let quicklink: Quicklink

        var id: String { "fallback:\(quicklink.id.uuidString)" }
    }

    var body: some View {
        let candidates = store.fallbackCandidates
        Section {
            if candidates.isEmpty {
                Text("None of your quicklinks asks for exactly one argument.")
                    .foregroundStyle(.secondary)
            }
            ForEach(candidates.enumerated().map(Row.init)) { row in
                let (index, quicklink) = (row.index, row.quicklink)
                HStack(spacing: 10) {
                    Text(quicklink.name)
                    Spacer()
                    Button("Move Up", systemImage: "chevron.up") {
                        store.moveFallbackCandidate(quicklink.id, by: -1)
                    }
                    .disabled(index == 0)
                    .help("Offer \(quicklink.name) earlier")
                    Button("Move Down", systemImage: "chevron.down") {
                        store.moveFallbackCandidate(quicklink.id, by: 1)
                    }
                    .disabled(index == candidates.count - 1)
                    .help("Offer \(quicklink.name) later")
                    Toggle("Use \(quicklink.name) as a fallback", isOn: Binding(
                        get: { quicklink.isFallback },
                        set: { store.setFallback(quicklink.id, $0) }
                    ))
                    .labelsHidden()
                }
                .labelStyle(.iconOnly)
            }
        } header: {
            Text("Fallback commands")
        } footer: {
            Text("Listed below the results of every search, with what you typed as their argument. When nothing was found, Return runs the first one. Any quicklink with exactly one argument can be a fallback.")
        }
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
