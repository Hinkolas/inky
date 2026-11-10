import Foundation
import Observation
import ServiceManagement

/// User settings, stored in UserDefaults.
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored var onHotkeyChange: (() -> Void)?
    @ObservationIgnored var onMenuBarChange: (() -> Void)?

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
        defaults.register(defaults: [Key.showMenuBarIcon: true, Key.fileSearchLimit: 8])
        hotkey = defaults.data(forKey: Key.hotkey)
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .defaultLauncher
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
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
        static let fileSearchLimit = "fileSearchLimit"
        static let disabledProviders = "disabledProviders"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }
}
