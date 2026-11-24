import Foundation
import Testing
@testable import InkyCore

@Suite struct SettingsPaneTests {
    /// A folder of made-up extensions, and one of made-up preference panes.
    private final class Folders {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inky-settings-\(UUID().uuidString)").path
        var extensions: String { root + "/Extensions" }
        var preferencePanes: String { root + "/PreferencePanes" }

        deinit {
            try? FileManager.default.removeItem(atPath: root)
        }

        /// An extension of System Settings, unless `point` says otherwise.
        func addPane(
            _ file: String,
            identifier: String,
            name: String? = nil,
            point: String = SettingsPaneScanner.extensionPoint,
            settings: [String: Any] = ["allowsXAppleSystemPreferencesURLScheme": true],
            strings: [String: String] = [:]
        ) throws {
            var info: [String: Any] = [
                "CFBundleIdentifier": identifier,
                "CFBundleDevelopmentRegion": "en",
                "EXAppExtensionAttributes": [
                    "EXExtensionPointIdentifier": point,
                    "SettingsExtensionAttributes": settings,
                ],
            ]
            info["CFBundleDisplayName"] = name
            try write(info, strings: strings, to: "\(extensions)/\(file).appex")
        }

        func addPreferencePane(_ file: String, info: [String: Any]) throws {
            try write(info, strings: [:], to: "\(preferencePanes)/\(file).prefPane")
        }

        private func write(_ info: [String: Any], strings: [String: String], to bundle: String) throws {
            try FileManager.default.createDirectory(atPath: bundle + "/Contents/Resources/en.lproj", withIntermediateDirectories: true)
            #expect((info as NSDictionary).write(toFile: bundle + "/Contents/Info.plist", atomically: true))
            if !strings.isEmpty {
                #expect((strings as NSDictionary).write(toFile: bundle + "/Contents/Resources/en.lproj/Localizable.strings", atomically: true))
            }
        }

        func scan(_ facts: SettingsPaneScanner.Facts = .init(values: [:])) -> [SettingsPane] {
            SettingsPaneScanner.scan(extensionFolder: extensions, preferencePaneFolders: [preferencePanes], facts: facts)
        }
    }

    private static var battery: [String: Any] { [
        "allowsXAppleSystemPreferencesURLScheme": true,
        "representations": [
            ["predicate": "powersource.battery != YES", "sidebar-name": "ENERGY_PREF_TITLE",
             "sidebar-iconUTTypeIdentifier": "com.apple.graphic-icon.energy"],
            ["predicate": "powersource.battery == YES", "sidebar-name": "BATTERY_PREF_TITLE",
             "sidebar-iconUTTypeIdentifier": "com.apple.graphic-icon.battery"],
        ],
    ] }

    @Test func listsThePanesOfSystemSettings() throws {
        let folders = Folders()
        try folders.addPane("Wi-Fi", identifier: "com.apple.wifi-settings-extension", name: "Wi‑Fi")
        try folders.addPane("LoginItems", identifier: "com.apple.LoginItems-Settings.extension", name: "Login Items", settings: [
            "allowsXAppleSystemPreferencesURLScheme": true,
            "alt_name": "Login Items & Extensions",
        ])

        let panes = folders.scan()
        #expect(panes.map(\.name) == ["Login Items", "Wi‑Fi"])
        let wifi = try #require(panes.last)
        #expect(wifi.id == "com.apple.wifi-settings-extension")
        #expect(wifi.path == folders.extensions + "/Wi-Fi.appex")
        #expect(wifi.target == .link("x-apple.systempreferences:com.apple.wifi-settings-extension"))
        #expect(panes.first?.alternateNames == ["Login Items & Extensions"])
    }

    @Test func leavesOutWhatIsNoPaneToOpen() throws {
        let folders = Folders()
        try folders.addPane("Thumbnails", identifier: "com.apple.thumbnails", name: "Thumbnails", point: "com.apple.quicklook.thumbnail")
        try folders.addPane("Home", identifier: "com.apple.Home.PrivacySettingsExtension", name: "Home", settings: [:])
        try folders.addPane("FollowUps", identifier: "com.apple.FollowUpSettings.FollowUpSettingsExtension", name: "FollowUps")
        try folders.addPane("Headphones", identifier: "com.apple.HeadphoneSettings", name: "HeadphoneSettingsExtension")
        try folders.addPane("Unnamed", identifier: "com.apple.unnamed")
        #expect(folders.scan().isEmpty)
    }

    @Test func namesAPaneAfterWhatTheMacHas() throws {
        let folders = Folders()
        try folders.addPane("PowerPreferences", identifier: "com.apple.Battery-Settings.extension", name: "PowerPreferences",
                            settings: Self.battery, strings: ["ENERGY_PREF_TITLE": "Energy", "BATTERY_PREF_TITLE": "Battery"])
        let battery = try #require(folders.scan(.init(values: ["powersource.battery": true])).first)
        #expect(battery.name == "Battery")
        #expect(battery.iconType == "com.apple.graphic-icon.battery")
        let energy = try #require(folders.scan(.init(values: ["powersource.battery": false])).first)
        #expect(energy.name == "Energy")
        #expect(energy.iconType == "com.apple.graphic-icon.energy")
    }

    @Test func hidesAPaneTheMacHasNoUseFor() throws {
        let folders = Folders()
        try folders.addPane("TouchID", identifier: "com.apple.Touch-ID-Settings.extension", name: "Touch ID & Password", settings: [
            "allowsXAppleSystemPreferencesURLScheme": true,
            "representations": [
                ["hidden": true, "predicate": "user.isguest == YES"],
                ["predicate": "device.touchID != YES", "sidebar-name": "Login Password"],
                ["predicate": "device.touchID == YES", "sidebar-name": "Touch ID & Password"],
            ],
        ])
        #expect(folders.scan(.init(values: ["user.isguest": false, "device.touchID": true])).map(\.name) == ["Touch ID & Password"])
        #expect(folders.scan(.init(values: ["user.isguest": false, "device.touchID": false])).map(\.name) == ["Login Password"])
        #expect(folders.scan(.init(values: ["user.isguest": true, "device.touchID": true])).isEmpty)
    }

    @Test func readsTheSettingThatShowsAPane() throws {
        let folders = Folders()
        let preference = [["domain": "com.apple.GameController", "key": "showGCPrefsPane"]]
        try folders.addPane("GameControllers", identifier: "com.apple.Game-Controller-Settings.extension", name: "Game Controllers", settings: [
            "allowsXAppleSystemPreferencesURLScheme": true,
            "representations": [
                ["predicate": "showGCPrefsPane == YES", "values_from_preferences": preference],
                ["hidden": true, "predicate": "showGCPrefsPane != YES", "values_from_preferences": preference],
            ],
        ])
        let shown = SettingsPaneScanner.Facts(values: [:]) { key, domain in
            key == "showGCPrefsPane" && domain == "com.apple.GameController"
        }
        #expect(folders.scan(shown).map(\.name) == ["Game Controllers"])
        // A setting never made is one that is off.
        #expect(folders.scan(.init(values: [:])).isEmpty)
    }

    @Test func listsAPaneWhoseConditionIsNotKnown() throws {
        let folders = Folders()
        try folders.addPane("Mouse", identifier: "com.apple.Mouse-Settings.extension", name: "Mouse", settings: [
            "allowsXAppleSystemPreferencesURLScheme": true,
            "representations": [
                ["predicate": "device.mouse == YES"],
                ["hidden": true, "predicate": "device.mouse != YES"],
            ],
        ])
        #expect(folders.scan().map(\.name) == ["Mouse"])
    }

    @Test func listsAPaneInsideAnother() throws {
        let folders = Folders()
        try folders.addPane("AppleID", identifier: "com.apple.systempreferences.AppleIDSettings", name: "Apple Account", settings: [
            "allowsXAppleSystemPreferencesURLScheme": true,
            "scenes": ["icloud": ["label": "ICLOUD_SCENE_LABEL", "iconUTTypeIdentifier": "com.apple.application-icon.icloud"]],
        ], strings: ["ICLOUD_SCENE_LABEL": "iCloud"])

        let panes = folders.scan()
        #expect(panes.map(\.name) == ["Apple Account", "iCloud"])
        #expect(panes.last?.id == "com.apple.systempreferences.AppleIDSettings:icloud")
        #expect(panes.first?.iconType == nil)
        #expect(panes.last?.iconType == "com.apple.application-icon.icloud")
        #expect(panes.last?.target == .link("x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?icloud"))
    }

    @Test func listsThePanesOfOtherApplications() throws {
        let folders = Folders()
        try folders.addPreferencePane("Thing", info: ["CFBundleIdentifier": "dev.example.thing.prefpane", "NSPrefPaneIconLabel": "Thing\nSettings"])
        try folders.addPreferencePane("Bare", info: [:])

        let panes = folders.scan()
        #expect(panes.map(\.name) == ["Bare", "Thing Settings"])
        #expect(panes.last?.alternateNames == ["Thing"])
        #expect(panes.last?.target == .file(folders.preferencePanes + "/Thing.prefPane"))
    }

    @Test func checksConditions() {
        let facts = SettingsPaneScanner.Facts(values: ["device.touchID": true])
        #expect(SettingsPaneScanner.holds(nil, facts: facts) == true)
        #expect(SettingsPaneScanner.holds("device.touchID == YES", facts: facts) == true)
        #expect(SettingsPaneScanner.holds("device.touchID != YES", facts: facts) == false)
        #expect(SettingsPaneScanner.holds("device.touchID == NO", facts: facts) == false)
        #expect(SettingsPaneScanner.holds("device.mouse == YES", facts: facts) == nil)
        #expect(SettingsPaneScanner.holds("device.touchID > 2", facts: facts) == nil)
    }
}

@MainActor
@Suite struct SystemSettingsModuleTests {
    @Test func opensAPaneFromTheSearch() async throws {
        let pane = SettingsPane(
            id: "com.apple.wifi-settings-extension", name: "Wi‑Fi", path: "/System/Library/ExtensionKit/Extensions/Wi-Fi.appex",
            target: .link("x-apple.systempreferences:com.apple.wifi-settings-extension")
        )
        var opened: [URL] = []
        let module = SystemSettingsModule(scan: { [pane] }, open: { opened.append($0); return true })

        let item = try #require(await module.candidates().first)
        #expect(item.id == "settings:com.apple.wifi-settings-extension")
        #expect(item.title == "Wi‑Fi")
        #expect(item.subtitle == "System Settings")
        #expect(item.kind == "Settings")
        #expect(item.icon == .file(path: pane.path))

        try await item.actions[0].perform(ActionContext())
        #expect(opened == [URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")])
    }

    @Test func showsTheIconSystemSettingsShows() async throws {
        let pane = SettingsPane(
            id: "com.apple.Battery-Settings.extension", name: "Battery", path: "/PowerPreferences.appex",
            iconType: "com.apple.graphic-icon.battery", target: .link("x-apple.systempreferences:com.apple.Battery-Settings.extension")
        )
        let item = try #require(await SystemSettingsModule(scan: { [pane] }).candidates().first)
        #expect(item.icon == .type(identifier: "com.apple.graphic-icon.battery"))
    }

    @Test func findsThePanesOfThisMac() {
        // Whatever the Mac, System Settings has a General pane.
        #expect(SettingsPaneScanner.scan().contains { $0.id == "com.apple.systempreferences.GeneralSettings" })
    }
}
