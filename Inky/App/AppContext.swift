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

    private var settingsWindow: SettingsWindowController?
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
            retention: preferences.clipboardRetention
        )
        preferences.onClipboardRetentionChange = { [preferences, clipboard] in
            clipboard.retention = preferences.clipboardRetention
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
            fallbacks: fallbacks
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
        preferences.onModulesChange = { [unowned self] in updateClipboardRecording() }
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

    /// Shows the clipboard history, or closes it, as its hotkey does.
    func toggleClipboard() {
        guard preferences.isEnabled(clipboardModule.id) else { return }
        launcher.toggleClipboard()
    }

    /// Fetches every website icon again, in the background.
    func refreshFavicons() {
        favicons.refreshAll(including: quicklinks.quicklinks.compactMap { Favicon.host(of: $0.link) })
    }

    func showSettings(pane: String? = nil, activating: Bool = true) {
        launcher.hide()
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(context: self)
        }
        settingsWindow?.show(pane: pane, activating: activating)
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
