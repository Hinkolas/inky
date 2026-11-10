import AppKit
import InkyCore

/// Builds the app's long-lived objects and wires them together.
final class AppContext {
    let preferences = Preferences.shared
    let quicklinks: QuicklinkStore
    let favicons: FaviconStore
    let exchangeRates: ExchangeRateStore
    let engine: SearchEngine
    let launcher: LauncherController
    let fileProvider = FileProvider()

    private var settingsWindow: SettingsWindowController?

    init() {
        #if DEBUG
        let directory = DebugLaunch.dataDirectory ?? AppSupport.directory
        let caches = DebugLaunch.dataDirectory ?? AppSupport.cacheDirectory
        #else
        let directory = AppSupport.directory
        let caches = AppSupport.cacheDirectory
        #endif
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

        let commands = InkyCommandProvider()
        let quicklinkProvider = QuicklinkProvider(store: quicklinks)
        fileProvider.maxResults = preferences.fileSearchLimit

        // This order is the order of sections when nothing is typed.
        engine = SearchEngine(
            providers: [
                quicklinkProvider,
                commands,
                SystemProvider(),
                ApplicationProvider(),
                CalculatorProvider(exchangeRates: exchangeRates),
                fileProvider,
            ],
            usage: UsageStore(fileURL: directory.appendingPathComponent("usage.json"))
        )
        engine.isEnabled = { [preferences] id in preferences.isEnabled(id) }

        launcher = LauncherController(engine: engine, quicklinks: quicklinks)
        launcher.model.openSettings = { [unowned self] in showSettings() }
        launcher.model.configureFallbacks = { [unowned self] in showSettings(pane: quicklinkProvider.id) }

        commands.openSettings = { [unowned self] in showSettings() }
        commands.createQuicklink = { [unowned self] in launcher.model.editQuicklink(nil) }
        commands.manageQuicklinks = { [unowned self] in launcher.model.showQuicklinks() }
        quicklinkProvider.onEdit = { [unowned self] quicklink in launcher.model.editQuicklink(quicklink) }
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
final class InkyCommandProvider: Provider {
    let id = "inky"
    let info = ProviderInfo(
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
