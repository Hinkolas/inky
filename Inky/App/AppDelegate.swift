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
/// `--show`, `--pin`, `--quiet`, `--query <text>`, `--keys "tab a cmd+k"`,
/// `--settings [pane]`, `--new-quicklink`.
enum DebugLaunch {
    static func apply(to context: AppContext) {
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--")
            else { return nil }
            return arguments[index + 1]
        }

        let quiet = arguments.contains("--quiet")
        context.launcher.isPinned = arguments.contains("--pin")
        context.launcher.debugQuiet = quiet
        if arguments.contains("--settings") {
            context.showSettings(pane: value(after: "--settings"), activating: !quiet)
        }
        guard arguments.contains("--show") || arguments.contains("--query") || arguments.contains("--new-quicklink") else {
            return
        }
        Task {
            await context.engine.reloadAll()
            context.launcher.show()
            if let query = value(after: "--query") {
                context.launcher.model.setQuery(query)
            }
            if arguments.contains("--new-quicklink") {
                context.launcher.model.editQuicklink(nil)
            }
            for key in (value(after: "--keys") ?? "").split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(120))
                context.launcher.debugPress(String(key))
            }
            try? await Task.sleep(for: .milliseconds(300))
            FileHandle.standardError.write(Data((context.launcher.debugState + "\n").utf8))
        }
    }
}
#endif
