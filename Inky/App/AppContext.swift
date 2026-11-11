import AppKit
import InkyCore

/// Builds the app's long-lived objects and wires them together.
final class AppContext {
    let preferences = Preferences.shared
    let quicklinks: QuicklinkStore
    let favicons: FaviconStore
    let exchangeRates: ExchangeRateStore
    let engine: SearchEngine
    let uninstaller: ApplicationUninstaller
    let clipboard: ClipboardHistory
    let launcher: LauncherController
    let fileModule = FileModule()

    /// Called when the commands that can be run, or their hotkeys, may have
    /// changed.
    var onCommandsChange: () -> Void = {}

    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private let clipboardModule = ClipboardModule()
    /// False until the app says that what is copied may be kept.
    private var recordsClipboard = false

    init() {
        #if DEBUG
        let directory = DebugLaunch.dataDirectory ?? AppSupport.directory
        let caches = DebugLaunch.dataDirectory ?? AppSupport.cacheDirectory
        // A run with data of its own uninstalls only what is in that folder,
        // so nothing it does can reach a real application.
        uninstaller = DebugLaunch.dataDirectory.map {
            ApplicationUninstaller(home: $0.path, coversSystem: false)
        } ?? ApplicationUninstaller()
        // And it has a pasteboard to itself: what the user copies is not
        // read, and what it copies does not replace it.
        let pasteboard = DebugLaunch.dataDirectory == nil ? NSPasteboard.general : NSPasteboard.withUniqueName()
        #else
        let directory = AppSupport.directory
        let caches = AppSupport.cacheDirectory
        uninstaller = ApplicationUninstaller()
        let pasteboard = NSPasteboard.general
        #endif
        clipboard = ClipboardHistory(
            store: ClipboardStore(directory: directory.appendingPathComponent("Clipboard", isDirectory: true)),
            pasteboard: pasteboard,
            retention: preferences.clipboardRetention,
            keepsConcealed: preferences.clipboardKeepsConcealed
        )
        preferences.onClipboardRetentionChange = { [preferences, clipboard] in
            clipboard.retention = preferences.clipboardRetention
        }
        preferences.onClipboardConcealedChange = { [preferences, clipboard] in
            clipboard.keepsConcealed = preferences.clipboardKeepsConcealed
        }
        quicklinks = QuicklinkStore(fileURL: directory.appendingPathComponent("quicklinks.json"))

        favicons = FaviconStore(
            directory: caches.appendingPathComponent("Favicons", isDirectory: true),
            source: preferences.faviconSource
        )
        IconCache.shared.favicons = favicons
        preferences.onFaviconSourceChange = { [preferences, favicons] in
            favicons.source = preferences.faviconSource
        }

        exchangeRates = ExchangeRateStore(
            directory: caches.appendingPathComponent("ExchangeRates", isDirectory: true),
            source: preferences.exchangeRateSource
        )
        preferences.onExchangeRateSourceChange = { [preferences, exchangeRates] in
            exchangeRates.source = preferences.exchangeRateSource
        }

        let calculator = CalculatorModule(exchangeRates: exchangeRates)
        calculator.pixelsPerRem = Double(preferences.pixelsPerRem)
        preferences.onPixelsPerRemChange = { [preferences, calculator] in
            calculator.pixelsPerRem = Double(preferences.pixelsPerRem)
        }

        let commands = InkyCommandModule()
        let quicklinkModule = QuicklinkModule(store: quicklinks)
        let applications = ApplicationModule(uninstaller: uninstaller)
        fileModule.maxResults = preferences.fileSearchLimit

        let usage = UsageStore(fileURL: directory.appendingPathComponent("usage.json"))
        // Until the user chooses, the fallbacks are what the quicklinks say.
        let fallbacks = FallbackStore(
            fileURL: directory.appendingPathComponent("fallbacks.json"),
            initial: quicklinks.initialFallbacks
        )

        // The clipboard history had a hotkey before any other command could.
        let commandStore = CommandStore(
            fileURL: directory.appendingPathComponent("commands.json"),
            initialHotkeys: preferences.formerClipboardHotkey.map { [ClipboardModule.historyID: $0] } ?? [:]
        )

        // This order is the order of sections when nothing is typed.
        engine = SearchEngine(
            modules: [
                quicklinkModule,
                commands,
                clipboardModule,
                SystemModule(),
                applications,
                calculator,
                TimeModule(),
                ColorModule(usage: usage),
                fileModule,
            ],
            usage: usage,
            fallbacks: fallbacks,
            commands: commandStore
        )
        engine.isEnabled = { [preferences] id in preferences.isEnabled(id) }

        launcher = LauncherController(engine: engine, quicklinks: quicklinks, uninstaller: uninstaller, clipboard: clipboard)
        launcher.model.pastesOnReturn = { [preferences] in preferences.clipboardPastes }
        #if DEBUG
        // A run with data of its own must not type into the user's applications.
        launcher.model.pressesKeys = DebugLaunch.dataDirectory == nil
        #endif
        launcher.model.openSettings = { [unowned self] in showSettings() }
        launcher.model.configureFallbacks = { [unowned self] in showSettings(pane: "fallbacks") }
        launcher.model.configureCommand = { [unowned self] item in showSettings(pane: "commands", search: item.title) }

        commands.openSettings = { [unowned self] in showSettings() }
        commands.createQuicklink = { [unowned self] in launcher.model.editQuicklink(nil) }
        commands.manageQuicklinks = { [unowned self] in launcher.model.showQuicklinks() }
        quicklinkModule.onEdit = { [unowned self] quicklink in launcher.model.editQuicklink(quicklink) }
        quicklinkModule.onDelete = { [unowned self] quicklink in launcher.model.deleteQuicklink(quicklink) }
        applications.onUninstall = { [unowned self] app in launcher.model.reviewUninstall(of: app) }
        applications.onChooseUninstall = { [unowned self] in launcher.model.showUninstaller() }
        // The module lists the applications again, without the one that went.
        launcher.model.applicationsDidChange = { [applications] in applications.onChange?() }

        clipboardModule.onOpen = { [unowned self] in launcher.model.showClipboard() }
        clipboardModule.onClear = { [clipboard] in
            Task { await clipboard.clear() }
        }
        preferences.onModulesChange = { [unowned self] in
            updateClipboardRecording()
            onCommandsChange()
        }
        commandStore.onChange = { [unowned self] in onCommandsChange() }
        // A command is there to be run once its module has listed it.
        let refreshLauncher = engine.onChange
        engine.onChange = { [unowned self] in
            refreshLauncher?()
            onCommandsChange()
        }
    }

    /// Begins to keep what is copied, for as long as the clipboard history is on.
    func startClipboard() {
        recordsClipboard = true
        updateClipboardRecording()
    }

    private func updateClipboardRecording() {
        guard recordsClipboard else { return }
        if preferences.isEnabled(clipboardModule.id) {
            clipboard.start()
        } else {
            clipboard.stop()
        }
    }

    /// Runs a command as its hotkey does, unless it or its module is off.
    func runCommand(_ id: String) {
        guard let item = engine.command(withID: id) else { return }
        launcher.run(item)
    }

    /// Fetches every website icon again, in the background.
    func refreshFavicons() {
        favicons.refreshAll(including: quicklinks.quicklinks.compactMap { Favicon.host(of: $0.link) })
    }

    /// `search` is what the list of all commands is narrowed down to.
    func showSettings(pane: String? = nil, search: String? = nil, activating: Bool = true) {
        launcher.hide()
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(context: self)
        }
        settingsWindow?.show(pane: pane, search: search, activating: activating)
    }

    /// Shows the welcome window. Once it closes, it is not shown by itself again.
    func showOnboarding(step: OnboardingStep? = nil, activating: Bool = true) {
        launcher.hide()
        if onboardingWindow == nil {
            let window = OnboardingWindowController(context: self)
            window.onClose = { [unowned self] in
                preferences.hasLaunchedBefore = true
                onboardingWindow = nil
            }
            onboardingWindow = window
        }
        onboardingWindow?.show(step: step, activating: activating)
    }
}

/// Inky's own commands.
final class InkyCommandModule: Module {
    let id = "inky"
    let info = ModuleInfo(
        title: "Inky",
        summary: "Commands for Inky itself.",
        icon: .symbol("drop.fill", tint: .indigo)
    )
    var onChange: (@MainActor () -> Void)?

    var openSettings: () -> Void = {}
    var createQuicklink: () -> Void = {}
    var manageQuicklinks: () -> Void = {}

    func candidates() async -> [ResultItem] {
        [
            ResultItem(
                id: "inky:create-quicklink",
                title: "Create Quicklink",
                icon: .symbol("link.badge.plus", tint: .purple),
                kind: "Command",
                keywords: ["New Quicklink", "Add Quicklink"],
                actions: [
                    Action("Create Quicklink", symbol: "link.badge.plus", behavior: .keepOpen) { [weak self] _ in
                        self?.createQuicklink()
                    },
                ]
            ),
            ResultItem(
                id: "inky:manage-quicklinks",
                title: "Manage Quicklinks",
                icon: .symbol("link", tint: .purple),
                kind: "Command",
                keywords: ["Edit Quicklinks", "Browse Quicklinks", "All Quicklinks"],
                actions: [
                    Action("Open", symbol: "link", behavior: .keepOpen) { [weak self] _ in
                        self?.manageQuicklinks()
                    },
                ]
            ),
            ResultItem(
                id: "inky:settings",
                title: "Inky Settings",
                icon: .symbol("gearshape.fill", tint: .indigo),
                kind: "Command",
                keywords: ["Preferences"],
                actions: [
                    Action("Open Settings", symbol: "gearshape") { [weak self] _ in
                        self?.openSettings()
                    },
                ]
            ),
            ResultItem(
                id: "inky:quit",
                title: "Quit Inky",
                icon: .symbol("xmark", tint: .gray),
                kind: "Command",
                actions: [
                    Action("Quit Inky", symbol: "xmark") { _ in
                        NSApp.terminate(nil)
                    },
                ]
            ),
        ]
    }
}
