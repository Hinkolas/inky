import AppKit
import InkyCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: AppContext!
    private var hotKey: GlobalHotKey?
    /// The hotkeys of commands that macOS accepted, by the command's id.
    private var commandHotKeys: [String: (combo: KeyCombo, hotKey: GlobalHotKey)] = [:]
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
        if Updates.isSupported {
            statusItem.onCheckForUpdates = { [weak context] in context?.updates.check() }
        }
        statusItem.setVisible(preferences.showMenuBarIcon)

        preferences.onHotkeyChange = { [weak self] in self?.registerHotKey() }
        context.onCommandsChange = { [weak self] in self?.registerCommandHotKeys() }
        preferences.onMenuBarChange = { [weak self] in
            self?.statusItem.setVisible(preferences.showMenuBarIcon)
        }
        registerHotKey()
        context.startClipboard()
        context.updates.start()

        Task {
            await context.engine.reloadAll()
        }

        // An app without a Dock icon that shows nothing on first launch looks
        // broken. Until the welcome window has been closed once, it greets.
        if !preferences.hasLaunchedBefore {
            context.showOnboarding()
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
        // Inky's own hotkey comes first: the keys it takes, no command gets.
        for registered in commandHotKeys.values {
            registered.hotKey.unregister()
        }
        commandHotKeys = [:]
        // While the user records a new hotkey the old ones must not fire.
        guard !preferences.isRecordingHotkey else { return }

        hotKey = GlobalHotKey(preferences.hotkey) { [weak self] in
            self?.context.launcher.toggle()
        }
        preferences.isHotkeyAvailable = hotKey != nil
        registerCommandHotKeys()
    }

    /// Brings the registered hotkeys in line with the commands that have
    /// one and can be run: those that are there, and not switched off.
    private func registerCommandHotKeys() {
        let preferences = context.preferences
        let engine = context.engine
        // Nothing fires while a new hotkey is recorded.
        let wanted = preferences.isRecordingHotkey
            ? [:]
            : engine.commandStore.hotkeys.filter { engine.command(withID: $0.key) != nil }

        for (id, registered) in commandHotKeys where wanted[id] != registered.combo {
            registered.hotKey.unregister()
            commandHotKeys[id] = nil
        }

        var unavailable: Set<String> = []
        var taken: Set<KeyCombo> = [preferences.hotkey]
        taken.formUnion(commandHotKeys.values.map(\.combo))
        // In the same order every time, should two commands want the same keys.
        for (id, combo) in wanted.sorted(by: { $0.key < $1.key }) where commandHotKeys[id] == nil {
            guard taken.insert(combo).inserted,
                  let hotKey = GlobalHotKey(combo, handler: { [weak self] in self?.context.runCommand(id) })
            else {
                unavailable.insert(id)
                continue
            }
            commandHotKeys[id] = (combo, hotKey)
        }
        if preferences.unavailableHotkeys != unavailable {
            preferences.unavailableHotkeys = unavailable
        }
    }
}

#if DEBUG
/// Launch arguments that put the app into a known state for development:
/// `--show`, `--pin`, `--quiet`, `--query <text>`,
/// `--keys "tab a cmd+k hide show clipboard run:<command id>"`,
/// `--settings [pane]`, `--search <text>`, `--onboarding [step]`, `--new-quicklink`, `--quicklinks`, `--uninstall [application]`,
/// `--clipboard [filter]`, `--clipboard-samples`,
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
            context.showSettings(pane: value(after: "--settings"), search: value(after: "--search"), activating: !quiet)
            // A quiet run loads nothing by itself, and the fallback commands
            // are listed from what the modules offer.
            if quiet {
                Task { await context.engine.reloadAll() }
            }
        }
        if arguments.contains("--onboarding") {
            context.showOnboarding(step: value(after: "--onboarding").flatMap(OnboardingStep.init(name:)), activating: !quiet)
            // The features and the examples are listed from the modules.
            if quiet {
                Task { await context.engine.reloadAll() }
            }
        }
        guard !Set(arguments).isDisjoint(with: ["--show", "--query", "--new-quicklink", "--quicklinks", "--uninstall", "--clipboard"]) else {
            return
        }
        Task {
            // Made-up copies, only ever into a history that is the run's own.
            if arguments.contains("--clipboard-samples"), dataDirectory != nil {
                await ClipboardSamples.fill(context.clipboard.store)
            }
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
            if arguments.contains("--clipboard") {
                context.launcher.model.showClipboard()
                // What to filter by: nothing is typed into a run without focus.
                if let query = value(after: "--clipboard"), case .clipboard(let browser) = context.launcher.model.route {
                    browser.query = query
                }
                // Read before the first key is pressed.
                try? await Task.sleep(for: .milliseconds(200))
            }
            for key in (value(after: "--keys") ?? "").split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(120))
                switch key {
                case "hide": context.launcher.hide()
                case "show": context.launcher.show()
                // As the hotkey of the clipboard history does.
                case "clipboard": context.runCommand(ClipboardModule.historyID)
                // As the hotkey of any command does: `run:inky:manage-quicklinks`.
                case _ where key.hasPrefix("run:"): context.runCommand(String(key.dropFirst(4)))
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
