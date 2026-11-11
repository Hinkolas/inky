import AppKit
import InkyCore
import Observation
import ServiceManagement

/// Whether Inky is drawn light or dark.
enum AppearanceMode: String, CaseIterable, Identifiable {
    /// Follow the Mac.
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Nil leaves the choice to the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// User settings, stored in UserDefaults.
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored var onHotkeyChange: (() -> Void)?
    @ObservationIgnored var onMenuBarChange: (() -> Void)?
    @ObservationIgnored var onAppearanceChange: (() -> Void)?
    @ObservationIgnored var onFaviconSourceChange: (() -> Void)?
    @ObservationIgnored var onExchangeRateSourceChange: (() -> Void)?
    @ObservationIgnored var onPixelsPerRemChange: (() -> Void)?
    @ObservationIgnored var onClipboardRetentionChange: (() -> Void)?
    /// Called when a module was turned on or off.
    @ObservationIgnored var onModulesChange: (() -> Void)?

    var hotkey: KeyCombo {
        didSet {
            defaults.set(try? JSONEncoder().encode(hotkey), forKey: Key.hotkey)
            onHotkeyChange?()
        }
    }

    /// Whether macOS accepted the hotkey. Set by the app after registering it.
    var isHotkeyAvailable = true

    /// True while the settings window is capturing a new hotkey.
    var isRecordingHotkey = false {
        didSet { onHotkeyChange?() }
    }

    var showMenuBarIcon: Bool {
        didSet {
            defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon)
            onMenuBarChange?()
        }
    }

    var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            onAppearanceChange?()
        }
    }

    /// Whether the launcher animates. The Mac's Reduce Motion still applies.
    var animations: Bool {
        didSet { defaults.set(animations, forKey: Key.animations) }
    }

    /// Where website icons come from, if anywhere.
    var faviconSource: FaviconSource {
        didSet {
            defaults.set(faviconSource.rawValue, forKey: Key.faviconSource)
            onFaviconSourceChange?()
        }
    }

    /// Where exchange rates come from, if anywhere.
    var exchangeRateSource: ExchangeRateSource {
        didSet {
            defaults.set(exchangeRateSource.rawValue, forKey: Key.exchangeRateSource)
            onExchangeRateSourceChange?()
        }
    }

    /// How many pixels the calculator takes a rem to be.
    var pixelsPerRem: Int {
        didSet {
            defaults.set(pixelsPerRem, forKey: Key.pixelsPerRem)
            onPixelsPerRemChange?()
        }
    }

    static let pixelsPerRemRange = 1...100

    var fileSearchLimit: Int {
        didSet { defaults.set(fileSearchLimit, forKey: Key.fileSearchLimit) }
    }

    /// How long the clipboard history keeps a copy.
    var clipboardRetention: ClipboardRetention {
        didSet {
            defaults.set(clipboardRetention.rawValue, forKey: Key.clipboardRetention)
            onClipboardRetentionChange?()
        }
    }

    /// Whether Return, in the clipboard history, pastes into the application
    /// the user is in. Otherwise it copies, and ⌘↵ pastes.
    var clipboardPastes: Bool {
        didSet { defaults.set(clipboardPastes, forKey: Key.clipboardPastes) }
    }

    /// Opens the clipboard history from anywhere. Nil until the user sets one.
    var clipboardHotkey: KeyCombo? {
        didSet {
            defaults.set(clipboardHotkey.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.clipboardHotkey)
            onHotkeyChange?()
        }
    }

    /// Whether macOS accepted the hotkey of the clipboard history.
    var isClipboardHotkeyAvailable = true

    private var disabledModules: Set<String> {
        didSet { defaults.set(disabledModules.sorted(), forKey: Key.disabledModules) }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Key.hasLaunchedBefore) }
    }

    private init() {
        defaults.register(defaults: [
            Key.showMenuBarIcon: true, Key.animations: true, Key.fileSearchLimit: 8, Key.pixelsPerRem: 16,
            Key.clipboardPastes: true,
        ])
        hotkey = defaults.data(forKey: Key.hotkey)
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .defaultLauncher
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppearanceMode.init) ?? .system
        animations = defaults.bool(forKey: Key.animations)
        faviconSource = defaults.string(forKey: Key.faviconSource).flatMap(FaviconSource.init) ?? .duckDuckGo
        exchangeRateSource = defaults.string(forKey: Key.exchangeRateSource).flatMap(ExchangeRateSource.init) ?? .ecb
        let pixels = defaults.integer(forKey: Key.pixelsPerRem)
        pixelsPerRem = Self.pixelsPerRemRange.contains(pixels) ? pixels : 16
        fileSearchLimit = defaults.integer(forKey: Key.fileSearchLimit)
        clipboardRetention = defaults.string(forKey: Key.clipboardRetention).flatMap(ClipboardRetention.init) ?? .threeMonths
        clipboardPastes = defaults.bool(forKey: Key.clipboardPastes)
        clipboardHotkey = defaults.data(forKey: Key.clipboardHotkey)
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
        // Modules were called providers before, and their switches were kept under that name.
        if defaults.object(forKey: Key.disabledModules) == nil,
           let disabled = defaults.stringArray(forKey: Key.disabledProviders) {
            defaults.set(disabled, forKey: Key.disabledModules)
        }
        defaults.removeObject(forKey: Key.disabledProviders)
        disabledModules = Set(defaults.stringArray(forKey: Key.disabledModules) ?? [])
    }

    func isEnabled(_ moduleID: String) -> Bool {
        !disabledModules.contains(moduleID)
    }

    func setEnabled(_ moduleID: String, _ enabled: Bool) {
        if enabled {
            disabledModules.remove(moduleID)
        } else {
            disabledModules.insert(moduleID)
        }
        onModulesChange?()
    }

    // MARK: - Launch at login

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    private enum Key {
        static let hotkey = "hotkey"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let appearance = "appearance"
        static let animations = "animations"
        static let faviconSource = "faviconSource"
        static let exchangeRateSource = "exchangeRateSource"
        static let pixelsPerRem = "pixelsPerRem"
        static let fileSearchLimit = "fileSearchLimit"
        static let clipboardRetention = "clipboardRetention"
        static let clipboardPastes = "clipboardPastes"
        static let clipboardHotkey = "clipboardHotkey"
        static let disabledModules = "disabledModules"
        static let disabledProviders = "disabledProviders"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }
}
