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
/// `--settings [pane]`, `--new-quicklink`, `--quicklinks`,
/// `--appearance light|dark`, `--backdrop light|dark`, `--data <folder>`.
enum DebugLaunch {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isQuiet: Bool { arguments.contains("--quiet") }

    /// A folder to keep quicklinks and usage in instead of the user's own,
    /// so a run can save and delete freely.
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
        if quiet, let backdrop = value(after: "--backdrop") {
            context.launcher.debugShowBackdrop(dark: backdrop == "dark")
        }
        if arguments.contains("--settings") {
            context.showSettings(pane: value(after: "--settings"), activating: !quiet)
        }
        guard !Set(arguments).isDisjoint(with: ["--show", "--query", "--new-quicklink", "--quicklinks"]) else {
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
            for key in (value(after: "--keys") ?? "").split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(120))
                switch key {
                case "hide": context.launcher.hide()
                case "show": context.launcher.show()
                default: context.launcher.debugPress(String(key))
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            FileHandle.standardError.write(Data((context.launcher.debugState + "\n").utf8))
        }
    }
}
#endif
