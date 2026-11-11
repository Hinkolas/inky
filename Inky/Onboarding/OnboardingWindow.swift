import AppKit
import InkyCore
import SwiftUI

/// The steps of the welcome window, in order.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case hotkey, features, clipboard, online, ready

    var id: Self { self }

    var title: String {
        switch self {
        case .hotkey: "Hotkey"
        case .features: "Features"
        case .clipboard: "Clipboard"
        case .online: "Online & Startup"
        case .ready: "Ready"
        }
    }

    /// For the debug flag: "hotkey", "features", "clipboard", "online" or "ready".
    init?(name: String) {
        guard let step = Self.allCases.first(where: { "\($0)" == name }) else { return nil }
        self = step
    }
}

@Observable
final class OnboardingNavigation {
    var step = OnboardingStep.hotkey
}

/// The window that greets a new user and asks for the settings that matter
/// most. Closing it, at any step, counts as having seen it.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let navigation = OnboardingNavigation()
    var onClose: () -> Void = {}

    static let size = NSSize(width: 700, height: 540)

    init(context: AppContext) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Inky"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentViewController = NSHostingController(
            rootView: OnboardingView(context: context, navigation: navigation) { [weak self] in
                self?.close()
                context.launcher.show()
            }
        )
        window.setContentSize(Self.size)
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(step: OnboardingStep? = nil, activating: Bool = true) {
        if let step { navigation.step = step }
        guard let window else { return }
        guard activating else {
            #if DEBUG
            window.level = .beneathDesktop
            #endif
            window.orderFrontRegardless()
            return
        }
        // Inky has no Dock icon, and is not active on its first launch.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Window

struct OnboardingView: View {
    let context: AppContext
    @Bindable var navigation: OnboardingNavigation
    let finish: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            StepList(current: $navigation.step)
                .frame(width: 184)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(SidebarBackground().ignoresSafeArea())

            Divider().ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    switch navigation.step {
                    case .hotkey: HotkeyStep(context: context)
                    case .features: FeaturesStep(context: context)
                    case .clipboard: ClipboardStep(context: context)
                    case .online: OnlineStep(preferences: context.preferences, updates: context.updates)
                    case .ready: ReadyStep(context: context)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity, alignment: .top)

                footer
            }
        }
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
    }

    private var footer: some View {
        let step = navigation.step
        let previous = OnboardingStep(rawValue: step.rawValue - 1)
        let next = OnboardingStep(rawValue: step.rawValue + 1)
        return HStack {
            if let previous {
                Button("Back") { navigation.step = previous }
            }
            Spacer()
            if let next {
                Button("Continue") { navigation.step = next }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Open Inky", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .padding(.top, 4)
    }
}

/// Where the user is, and a way to go back to any step.
private struct StepList: View {
    @Binding var current: OnboardingStep

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                IconView(icon: .inky, size: 22)
                Text("Inky").font(.headline)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

            ForEach(OnboardingStep.allCases) { step in
                Button {
                    current = step
                } label: {
                    HStack(spacing: 9) {
                        marker(for: step)
                        Text(step.title)
                            .fontWeight(step == current ? .semibold : .regular)
                            .foregroundStyle(step.rawValue <= current.rawValue ? .primary : .secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background {
                        if step == current {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.primary.opacity(0.07))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(step == current ? .isSelected : [])
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func marker(for step: OnboardingStep) -> some View {
        if step.rawValue < current.rawValue {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 15))
        } else {
            Image(systemName: "circle")
                .foregroundStyle(step == current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .font(.system(size: 15))
        }
    }
}

private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The icon, title and a line about the step, above its settings.
private struct StepHeader: View {
    let icon: Icon
    let title: String
    let summary: String

    var body: some View {
        HStack(spacing: 14) {
            IconView(icon: icon, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.body.weight(.regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// A row's title with a line below it.
private struct RowLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Granted: View {
    var body: some View {
        Label("Allowed", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .fontWeight(.medium)
    }
}

// MARK: - Steps

/// The clipboard history's module, which the clipboard step switches.
private let clipboardModuleID = "clipboard"

private struct HotkeyStep: View {
    let context: AppContext

    var body: some View {
        let preferences = context.preferences
        Form {
            Section {
                LabeledContent("Open Inky with") {
                    HotkeyRecorder(
                        combo: Binding(
                            get: { preferences.hotkey },
                            set: { if let combo = $0 { preferences.hotkey = combo } }
                        ),
                        onRecordingChange: { preferences.isRecordingHotkey = $0 }
                    )
                }
            } header: {
                StepHeader(
                    icon: .inky,
                    title: "Welcome to Inky",
                    summary: "A fast launcher for your Mac. Choose the keys that open it from anywhere."
                )
            } footer: {
                if !preferences.isHotkeyAvailable {
                    Text("macOS did not accept this shortcut. Choose a different one.")
                        .foregroundStyle(.red)
                } else {
                    Text("Click the shortcut to record a different one. Choose keys no other app uses; ⌘Space belongs to Spotlight unless you turn its shortcut off.")
                }
            }

            Section {
                LabeledContent("Search") {
                    Text("Apps, files, quicklinks, settings").foregroundStyle(.secondary)
                }
                LabeledContent("Ask") {
                    Text("Sums, units, currencies, times, colors").foregroundStyle(.secondary)
                }
                LabeledContent("Run") {
                    Text("Commands, each with its own hotkey").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct FeaturesStep: View {
    let context: AppContext

    var body: some View {
        let preferences = context.preferences
        Form {
            Section {
                ForEach(context.engine.modules.filter { $0.id != "inky" }, id: \.id) { module in
                    Toggle(isOn: Binding(
                        get: { preferences.isEnabled(module.id) },
                        set: { preferences.setEnabled(module.id, $0) }
                    )) {
                        HStack(spacing: 10) {
                            IconView(icon: module.info.icon, size: 22)
                            RowLabel(module.info.title, detail: module.info.summary)
                        }
                    }
                }
            } header: {
                StepHeader(
                    icon: .symbol("square.grid.2x2.fill", tint: .blue),
                    title: "Features",
                    summary: "Everything is on to begin with. Switch off what you will not use."
                )
            } footer: {
                Text("Each feature has its own page in Settings, with more to choose.")
            }
        }
    }
}

private struct ClipboardStep: View {
    let context: AppContext
    @State private var canPressKeys = KeyboardPaste.isAllowed
    @State private var readAccess = ReadAccess.current
    /// Why the keys pressed last could not open the history.
    @State private var refusal: String?

    var body: some View {
        @Bindable var preferences = context.preferences
        let isOn = preferences.isEnabled(clipboardModuleID)
        Form {
            Section {
                Toggle("Keep what I copy", isOn: Binding(
                    get: { isOn },
                    set: { preferences.setEnabled(clipboardModuleID, $0) }
                ))
                if isOn {
                    Picker("Keep history for", selection: $preferences.clipboardRetention) {
                        ForEach(ClipboardRetention.allCases) { retention in
                            Text(retention.title).tag(retention)
                        }
                    }
                    Toggle(isOn: $preferences.clipboardKeepsConcealed) {
                        RowLabel(
                            "Keep passwords from password managers",
                            detail: "Left out unless this is on. Kept ones are not encrypted."
                        )
                    }
                    LabeledContent {
                        HotkeyRecorder(
                            combo: Binding(
                                get: { store.hotkey(for: ClipboardModule.historyID) },
                                set: {
                                    refusal = nil
                                    store.setHotkey($0, for: ClipboardModule.historyID)
                                }
                            ),
                            refusal: { combo in
                                refusal = reason(against: combo)
                                return refusal
                            },
                            onRecordingChange: { isRecording in
                                if isRecording { refusal = nil }
                                preferences.isRecordingHotkey = isRecording
                            }
                        )
                    } label: {
                        RowLabel("Open the history with", detail: refusal ?? "Or search for “Clipboard History” in Inky.")
                    }
                }
            } header: {
                StepHeader(
                    icon: ClipboardModule.icon,
                    title: ClipboardModule.title,
                    summary: "Keeps what you copy, so you can find it and paste it again. Everything stays on this Mac."
                )
            }

            if isOn {
                Section("Permissions") {
                    LabeledContent {
                        switch readAccess {
                        case .allowed:
                            Granted()
                        case .asksOnce:
                            Text("Asked on first copy").foregroundStyle(.secondary)
                        case .blocked:
                            Button("Open Privacy Settings") { ClipDescription.openPasteSettings() }
                        }
                    } label: {
                        RowLabel("Read what other apps copy", detail: readAccess.detail)
                    }
                    LabeledContent {
                        if canPressKeys {
                            Granted()
                        } else {
                            Button("Allow…") { KeyboardPaste.requestAccess() }
                        }
                    } label: {
                        RowLabel(
                            "Paste for you",
                            detail: "Accessibility access, so Inky can press ⌘V. Without it, Inky copies and you paste."
                        )
                    }
                }
            }
        }
        // Neither permission says when it changes, and both are granted in
        // System Settings, so look again while this step is up.
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var store: CommandStore { context.engine.commandStore }

    private func refresh() {
        if canPressKeys != KeyboardPaste.isAllowed { canPressKeys = KeyboardPaste.isAllowed }
        let access = ReadAccess.current
        if readAccess != access { readAccess = access }
        context.clipboard.refreshAccess()
    }

    private func reason(against combo: KeyCombo) -> String? {
        if combo == context.preferences.hotkey {
            return "This hotkey already opens Inky. Choose a different one."
        }
        if let other = store.command(with: combo), other != ClipboardModule.historyID {
            let name = context.engine.item(withID: other)?.title ?? "another command"
            return "This is already the hotkey of \(name)."
        }
        return nil
    }

    /// Whether macOS lets Inky read what other apps copied, told apart more
    /// finely than the history needs to: here it matters whether macOS is
    /// still to ask.
    private enum ReadAccess: Equatable {
        case allowed, asksOnce, blocked

        static var current: ReadAccess {
            guard #available(macOS 15.4, *) else { return .allowed }
            return switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: .allowed
            case .default: .asksOnce
            case .ask, .alwaysDeny: .blocked
            @unknown default: .asksOnce
            }
        }

        var detail: String {
            switch self {
            case .allowed: "Inky may keep what you copy in other apps."
            case .asksOnce: "macOS asks the first time Inky reads a copy. Choose Allow."
            case .blocked: "Choose Allow for Inky under Paste from Other Apps, or nothing new is kept."
            }
        }
    }
}

private struct OnlineStep: View {
    @Bindable var preferences: Preferences
    @Bindable var updates: Updates
    @State private var launchesAtLogin = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker(selection: $preferences.faviconSource) {
                    ForEach(FaviconSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                } label: {
                    RowLabel("Website icons", detail: "Only a quicklink's domain name is sent.")
                }
                Picker(selection: $preferences.exchangeRateSource) {
                    ForEach(ExchangeRateSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                } label: {
                    RowLabel("Exchange rates", detail: "One file for everyone; nothing you convert is sent.")
                }
                if updates.isAvailable {
                    Toggle(isOn: $updates.checksAutomatically) {
                        RowLabel("Check for updates", detail: "Asks GitHub for Inky’s latest release.")
                    }
                }
            } header: {
                StepHeader(
                    icon: .symbol("globe", tint: .teal),
                    title: "Online & Startup",
                    summary: "What Inky may ask the internet for, and how it starts. Everything else stays on this Mac."
                )
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
                .pickerStyle(.segmented)
            } footer: {
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                } else if !preferences.showMenuBarIcon {
                    Text("Without the menu bar icon, open settings by searching for “Inky Settings”.")
                }
            }
        }
        .onAppear { launchesAtLogin = preferences.launchesAtLogin }
    }
}

private struct ReadyStep: View {
    let context: AppContext

    var body: some View {
        let preferences = context.preferences
        Form {
            Section {
                ForEach(examples, id: \.query) { example in
                    LabeledContent {
                        Text(example.what).foregroundStyle(.secondary)
                    } label: {
                        Text(example.query)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                if preferences.isEnabled(clipboardModuleID),
                   let combo = context.engine.commandStore.hotkey(for: ClipboardModule.historyID) {
                    LabeledContent {
                        Text("Your clipboard history").foregroundStyle(.secondary)
                    } label: {
                        Keycap(combo.symbols)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 10) {
                    StepHeader(
                        icon: .symbol("checkmark", tint: .green),
                        title: "You’re All Set",
                        summary: "Open Inky from anywhere, type, and press Return."
                    )
                    HStack(spacing: 6) {
                        Text("Press")
                        Keycap(preferences.hotkey.symbols)
                        Text("and try:")
                    }
                    .foregroundStyle(.primary)
                    .textCase(nil)
                }
            } footer: {
                Text("Everything here can be changed later in Settings. Search for “Inky Settings” to open them.")
            }
        }
    }

    private struct Example {
        let query: String
        let what: String
    }

    private var examples: [Example] {
        let preferences = context.preferences
        var examples: [Example] = []
        if preferences.isEnabled("applications") {
            examples.append(Example(query: "safari", what: "Open an app"))
        }
        if preferences.isEnabled("calculator") {
            examples.append(Example(query: "128 * 3 + 4", what: "Calculate"))
            if preferences.exchangeRateSource != .off {
                examples.append(Example(query: "100 usd in eur", what: "Convert currencies"))
            }
        }
        if preferences.isEnabled("time") {
            examples.append(Example(query: "time in tokyo", what: "Ask about times and days"))
        }
        if preferences.isEnabled(clipboardModuleID),
           context.engine.commandStore.hotkey(for: ClipboardModule.historyID) == nil {
            examples.append(Example(query: "clipboard", what: "Your clipboard history"))
        }
        return examples
    }
}
