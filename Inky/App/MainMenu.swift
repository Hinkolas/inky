import AppKit

/// Inky has no visible menu bar, but text fields rely on the Edit menu for
/// Copy, Paste and Undo, and the settings window on the rest.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Inky", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Inky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Inky")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

/// The menu bar icon and its menu.
final class StatusItemController: NSObject {
    var onOpen: () -> Void = {}
    var onSettings: () -> Void = {}

    private var item: NSStatusItem?

    func setVisible(_ visible: Bool) {
        guard visible else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }

        let item = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        item.button?.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Inky")

        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open Inky", action: #selector(open(_:)), keyEquivalent: "")
        open.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(settings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Inky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func open(_ sender: Any?) {
        onOpen()
    }

    @objc private func settings(_ sender: Any?) {
        onSettings()
    }
}

enum Alerts {
    /// Asks before a destructive action. Returns whether the user went ahead.
    static func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func show(error message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }
}
