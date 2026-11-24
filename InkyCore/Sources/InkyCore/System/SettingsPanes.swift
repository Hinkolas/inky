import Foundation
import IOKit
import IOKit.ps
import LocalAuthentication

/// A pane of System Settings, such as Wi‑Fi or Displays.
public struct SettingsPane: Identifiable, Sendable, Hashable {
    /// What System Settings knows the pane by: the identifier of its
    /// extension, and the part of it after a colon for a pane inside
    /// another, as iCloud is inside Apple Account.
    public var id: String
    /// The name System Settings shows, in the user's language.
    public var name: String
    /// Other names worth matching.
    public var alternateNames: [String]
    /// The bundle the pane comes from, for its icon.
    public var path: String
    /// The type whose icon System Settings shows for the pane, where that
    /// is not the icon of its bundle.
    public var iconType: String?
    /// What opens the pane: a link for a pane of macOS, the bundle itself
    /// for one another application installed.
    public var target: Target

    public enum Target: Sendable, Hashable {
        case link(String)
        case file(String)
    }

    public init(
        id: String,
        name: String,
        alternateNames: [String] = [],
        path: String,
        iconType: String? = nil,
        target: Target
    ) {
        self.id = id
        self.name = name
        self.alternateNames = alternateNames
        self.path = path
        self.iconType = iconType
        self.target = target
    }
}

/// Finds the panes of System Settings.
///
/// Every pane of macOS is an extension in `extensionFolder`, with its name
/// and icon. Some are shown only on some Macs, such as Touch ID, or are
/// named after what the Mac has, as Battery is Energy on a Mac without one:
/// the extension says so with a condition, which is checked here as far as
/// it can be. A pane whose condition cannot be checked is listed.
///
/// What other applications installed are the panes of before System
/// Settings, in the `PreferencePanes` folders.
public enum SettingsPaneScanner {
    public static let extensionFolder = "/System/Library/ExtensionKit/Extensions"
    public static let preferencePaneFolders = [
        "/Library/PreferencePanes",
        NSHomeDirectory() + "/Library/PreferencePanes",
    ]

    /// What marks an extension as a pane of System Settings.
    static let extensionPoint = "com.apple.Settings.extension.ui"

    /// Panes that System Settings shows only now and then, as something is
    /// to be done, or only where a school set them up.
    static let leftOut: Set<String> = [
        "com.apple.FollowUpSettings.FollowUpSettingsExtension",
        "com.apple.Classroom-Settings.extension",
    ]

    public static func scan(
        extensionFolder: String = extensionFolder,
        preferencePaneFolders: [String] = preferencePaneFolders,
        facts: Facts = .current()
    ) -> [SettingsPane] {
        var panes: [SettingsPane] = []
        for path in bundles(in: extensionFolder, withExtension: "appex") {
            panes += extensionPanes(at: path, facts: facts)
        }
        for folder in preferencePaneFolders {
            for path in bundles(in: folder, withExtension: "prefPane") {
                if let pane = preferencePane(at: path) { panes.append(pane) }
            }
        }
        return panes
    }

    private static func bundles(in folder: String, withExtension pathExtension: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension == pathExtension }
            .sorted()
            .map { folder + "/" + $0 }
    }

    // MARK: - Panes of macOS

    private static func extensionPanes(at path: String, facts: Facts) -> [SettingsPane] {
        guard let bundle = Bundle(path: path),
              let info = bundle.infoDictionary,
              let identifier = info["CFBundleIdentifier"] as? String,
              let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
              attributes["EXExtensionPointIdentifier"] as? String == extensionPoint,
              !leftOut.contains(identifier)
        else { return [] }
        let settings = attributes["SettingsExtensionAttributes"] as? [String: Any] ?? [:]
        // What System Settings cannot be asked to open is not listed.
        guard settings["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true else { return [] }

        var name: String?
        var iconType: String?
        if let representations = settings["representations"] as? [[String: Any]] {
            guard let shown = representation(of: representations, facts: facts) else { return [] }
            name = (shown["sidebar-name"] as? String).map { localized($0, in: bundle) }
            iconType = shown["sidebar-iconUTTypeIdentifier"] as? String
        }
        guard let name = name ?? bundleName(of: bundle, info: info) else { return [] }

        var alternates: [String] = []
        if let alternate = settings["alt_name"] as? String, alternate != name {
            alternates.append(alternate)
        }
        let link = "x-apple.systempreferences:" + identifier
        var panes = [SettingsPane(
            id: identifier, name: name, alternateNames: alternates, path: path, iconType: iconType, target: .link(link)
        )]

        // Panes inside this one that System Settings lists on their own.
        let scenes = settings["scenes"] as? [String: [String: Any]] ?? [:]
        for (scene, description) in scenes.sorted(by: { $0.key < $1.key }) {
            guard let label = description["label"] as? String else { continue }
            panes.append(SettingsPane(
                id: identifier + ":" + scene,
                name: localized(label, in: bundle),
                path: path,
                iconType: description["iconUTTypeIdentifier"] as? String,
                target: .link(link + "?" + scene)
            ))
        }
        return panes
    }

    /// The name of the pane, if it has one meant to be shown. A name made
    /// of words run together that ends in Extension is the one it was built
    /// with, as HeadphoneSettingsExtension: a pane for a device that is
    /// named after the device.
    private static func bundleName(of bundle: Bundle, info: [String: Any]) -> String? {
        let localized = bundle.localizedInfoDictionary ?? [:]
        let names = [localized["CFBundleDisplayName"], localized["CFBundleName"], info["CFBundleDisplayName"], info["CFBundleName"]]
        guard let name = names.lazy.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else { return nil }
        if !name.contains(" "), name.hasSuffix("Extension") || name.hasSuffix("Ext") { return nil }
        return name
    }

    private static func localized(_ key: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// Of the ways a pane can be shown, the one that holds on this Mac. Nil
    /// if that is to be hidden.
    static func representation(of representations: [[String: Any]], facts: Facts) -> [String: Any]? {
        var unknown: [[String: Any]] = []
        for representation in representations {
            let preferences = representation["values_from_preferences"] as? [[String: String]] ?? []
            switch holds(representation["predicate"] as? String, preferences: preferences, facts: facts) {
            case true?:
                return representation["hidden"] as? Bool == true ? nil : representation
            case false?:
                continue
            case nil:
                unknown.append(representation)
            }
        }
        // Nothing that is known holds: what is not known is taken to be
        // shown, rather than a pane the Mac may well have missing.
        return unknown.first { $0["hidden"] as? Bool != true }
    }

    /// Whether a condition such as `device.touchID == YES` holds. Nil for
    /// one that cannot be checked. No condition always holds.
    static func holds(_ predicate: String?, preferences: [[String: String]] = [], facts: Facts) -> Bool? {
        guard let predicate else { return true }
        let parts = predicate.split(separator: " ")
        guard parts.count == 3, ["==", "!="].contains(parts[1]), ["YES", "NO"].contains(parts[2]) else { return nil }
        let key = String(parts[0])

        var value = facts.values[key]
        if value == nil, let source = preferences.first(where: { $0["key"] == key }), let domain = source["domain"] {
            value = facts.preference(key, domain) ?? false
        }
        guard let value else { return nil }
        return (value == (parts[2] == "YES")) == (parts[1] == "==")
    }

    /// What the conditions of panes ask about this Mac.
    public struct Facts: Sendable {
        public var values: [String: Bool]
        /// A setting of another application, by its key and domain.
        public var preference: @Sendable (_ key: String, _ domain: String) -> Bool?

        public init(values: [String: Bool], preference: @escaping @Sendable (String, String) -> Bool? = { _, _ in nil }) {
            self.values = values
            self.preference = preference
        }

        public static func current() -> Facts {
            Facts(
                values: [
                    "powersource.battery": hasBattery(),
                    "device.touchID": hasTouchID(),
                    "device.cddvd": hasOpticalDrive(),
                    "user.isguest": NSUserName() == "Guest",
                ],
                preference: { key, domain in
                    CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Bool
                }
            )
        }

        private static func hasBattery() -> Bool {
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
            else { return false }
            return sources.contains { source in
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
                return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            }
        }

        private static func hasTouchID() -> Bool {
            let context = LAContext()
            // Sets what the Mac has, also when no finger was added yet.
            _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            return context.biometryType == .touchID
        }

        private static func hasOpticalDrive() -> Bool {
            ["IOCDServices", "IODVDServices", "IOBDServices"].contains { name in
                let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
                defer { if service != 0 { IOObjectRelease(service) } }
                return service != 0
            }
        }
    }

    // MARK: - Panes of other applications

    private static func preferencePane(at path: String) -> SettingsPane? {
        let bundle = Bundle(path: path)
        let localized = bundle?.localizedInfoDictionary ?? [:]
        let info = bundle?.infoDictionary ?? [:]
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let names = [localized["NSPrefPaneIconLabel"], localized["CFBundleName"], info["NSPrefPaneIconLabel"], info["CFBundleName"]]
        let name = names.lazy.compactMap { $0 as? String }.first { !$0.isEmpty }?
            .replacingOccurrences(of: "\n", with: " ") ?? fileName
        let identifier = info["CFBundleIdentifier"] as? String ?? path
        return SettingsPane(
            id: identifier,
            name: name,
            alternateNames: fileName == name ? [] : [fileName],
            path: path,
            target: .file(path)
        )
    }
}
