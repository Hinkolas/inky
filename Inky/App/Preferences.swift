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

    private var disabledProviders: Set<String> {
        didSet { defaults.set(disabledProviders.sorted(), forKey: Key.disabledProviders) }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Key.hasLaunchedBefore) }
    }

    private init() {
        defaults.register(defaults: [
            Key.showMenuBarIcon: true, Key.animations: true, Key.fileSearchLimit: 8, Key.pixelsPerRem: 16,
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
        disabledProviders = Set(defaults.stringArray(forKey: Key.disabledProviders) ?? [])
    }

    func isEnabled(_ providerID: String) -> Bool {
        !disabledProviders.contains(providerID)
    }

    func setEnabled(_ providerID: String, _ enabled: Bool) {
        if enabled {
            disabledProviders.remove(providerID)
        } else {
            disabledProviders.insert(providerID)
        }
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
        static let disabledProviders = "disabledProviders"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }
}
