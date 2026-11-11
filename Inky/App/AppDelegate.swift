import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: AppContext!
    private var hotKey: GlobalHotKey?
    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let context = AppContext()
        self.context = context
        let preferences = context.preferences

        NSApp.appearance = preferences.appearance.appearance
        preferences.onAppearanceChange = {
            NSApp.appearance = preferences.appearance.appearance
        }

        #if DEBUG
        // A quiet run must not be noticed: it shares the Mac, and the hotkey,
        // with whoever is using it, and possibly with their own Inky.
        if DebugLaunch.isQuiet {
            DebugLaunch.apply(to: context)
            return
        }
        #endif

        statusItem.onOpen = { [weak context] in context?.launcher.show() }
        statusItem.onSettings = { [weak context] in context?.showSettings() }
        statusItem.setVisible(preferences.showMenuBarIcon)

        preferences.onHotkeyChange = { [weak self] in self?.registerHotKey() }
        preferences.onMenuBarChange = { [weak self] in
            self?.statusItem.setVisible(preferences.showMenuBarIcon)
        }
        registerHotKey()

        Task {
            await context.engine.reloadAll()
        }

        // An app without a Dock icon that shows nothing on first launch looks broken.
        if !preferences.hasLaunchedBefore {
            preferences.hasLaunchedBefore = true
            context.launcher.show()
        }

        #if DEBUG
        DebugLaunch.apply(to: context)
        #endif
    }

    /// Opening Inky again, from Finder or Spotlight, shows the launcher.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        context.launcher.show()
        return false
    }

    @objc func showSettings(_ sender: Any?) {
        context.showSettings()
    }

    private func registerHotKey() {
        let preferences = context.preferences
        hotKey?.unregister()
        hotKey = nil
        // While the user records a new hotkey the old one must not fire.
        guard !preferences.isRecordingHotkey else { return }

        hotKey = GlobalHotKey(preferences.hotkey) { [weak self] in
            self?.context.launcher.toggle()
        }
        preferences.isHotkeyAvailable = hotKey != nil
    }
}

#if DEBUG
/// Launch arguments that put the app into a known state for development:
/// `--show`, `--pin`, `--quiet`, `--query <text>`, `--keys "tab a cmd+k hide show"`,
/// `--settings [pane]`, `--new-quicklink`, `--quicklinks`, `--uninstall [application]`,
/// `--appearance light|dark`, `--backdrop light|dark`, `--data <folder>`,
/// `--motion full|reduced|off`, `--slow <factor>`.
///
/// To look at an animation, stretch it with `--slow` and put `mark` before
/// the key that starts it: `--keys "wait mark return"`. `mark` prints a line
/// to wait for, `wait` pauses for a second.
enum DebugLaunch {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isQuiet: Bool { arguments.contains("--quiet") }

    /// A folder to keep quicklinks and usage in instead of the user's own,
    /// so a run can save and delete freely. It is also the only place
    /// applications are uninstalled from: the ones in its `Applications`,
    /// with what they left in its `Library`.
    static var dataDirectory: URL? {
        guard let path = value(after: "--data") else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("--")
        else { return nil }
        return arguments[index + 1]
    }

    static func apply(to context: AppContext) {
        let quiet = isQuiet
        context.launcher.isPinned = arguments.contains("--pin")
        context.launcher.debugQuiet = quiet
        // Overrides the setting for this run only.
        if let appearance = value(after: "--appearance").flatMap(AppearanceMode.init) {
            NSApp.appearance = appearance.appearance
        }
        Motion.debugLevel = value(after: "--motion").flatMap(Motion.Level.init)
        if let slowdown = value(after: "--slow").flatMap(Double.init), slowdown > 0 {
            Motion.debugSlowdown = slowdown
        }
        if quiet, let backdrop = value(after: "--backdrop") {
            context.launcher.debugShowBackdrop(dark: backdrop == "dark")
        }
        if arguments.contains("--settings") {
            context.showSettings(pane: value(after: "--settings"), activating: !quiet)
            // A quiet run loads nothing by itself, and the fallback commands
            // are listed from what the modules offer.
            if quiet {
                Task { await context.engine.reloadAll() }
            }
        }
        guard !Set(arguments).isDisjoint(with: ["--show", "--query", "--new-quicklink", "--quicklinks", "--uninstall"]) else {
            return
        }
        Task {
            await context.engine.reloadAll()
            context.launcher.show()
            if let query = value(after: "--query") {
                context.launcher.model.setQuery(query)
            }
            if arguments.contains("--quicklinks") {
                context.launcher.model.showQuicklinks()
            }
            if arguments.contains("--new-quicklink") {
                context.launcher.model.editQuicklink(nil)
            }
            if arguments.contains("--uninstall") {
                // The list to choose from, or what would go with the named one.
                let name = value(after: "--uninstall")
                let app = context.uninstaller.installedApplications().first {
                    $0.name.caseInsensitiveCompare(name ?? "") == .orderedSame && context.uninstaller.canUninstall($0)
                }
                if let app {
                    context.launcher.model.reviewUninstall(of: app)
                } else {
                    context.launcher.model.showUninstaller()
                }
            }
            for key in (value(after: "--keys") ?? "").split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(120))
                switch key {
                case "hide": context.launcher.hide()
                case "show": context.launcher.show()
                case "wait": try? await Task.sleep(for: .seconds(1))
                case "mark": FileHandle.standardError.write(Data("MARK\n".utf8))
                default: context.launcher.debugPress(String(key))
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            FileHandle.standardError.write(Data((context.launcher.debugState + "\n").utf8))
        }
    }
}
#endif
