import AppKit
import InkyCore
import SwiftUI

enum LauncherMetrics {
    static let size = NSSize(width: 750, height: 474)
    static let cornerRadius: CGFloat = 16
    static let searchBarHeight: CGFloat = 56
    static let footerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 40
}

/// The floating window. It takes keyboard focus without activating Inky, so
/// the app the user was in stays frontmost and gets focus back on dismissal.
final class LauncherPanel: NSPanel {
    /// Sees every key press before the focused text field. Returns true to consume it.
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: LauncherMetrics.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handle(event) || super.performKeyEquivalent(with: event) { return true }

        // Inky is not the active app while the panel is up, so its Edit menu
        // is not consulted. Send the editing shortcuts to the text field directly.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let action: Selector? = switch (key, modifiers) {
        case ("a", .command): #selector(NSText.selectAll(_:))
        case ("c", .command): #selector(NSText.copy(_:))
        case ("v", .command): #selector(NSText.paste(_:))
        case ("x", .command): #selector(NSText.cut(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        default: nil
        }
        guard let action else { return false }
        return firstResponder?.tryToPerform(action, with: nil) ?? false
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Keys pressed while composing text (Japanese, accents) belong to the input method.
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        return keyHandler?(event) ?? false
    }
}

#if DEBUG
extension NSWindow.Level {
    /// Still drawn and capturable, but hidden behind the wallpaper.
    static let beneathDesktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
}
#endif

/// Owns the panel: shows, hides and positions it.
final class LauncherController: NSObject, NSWindowDelegate {
    let model: LauncherModel
    /// Keeps the panel open when it loses focus. For development.
    var isPinned = false

    private let panel = LauncherPanel()

    init(engine: SearchEngine, quicklinks: QuicklinkStore) {
        model = LauncherModel(engine: engine, quicklinks: quicklinks)
        super.init()

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = LauncherMetrics.cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true

        let content = NSHostingView(rootView: LauncherView(model: model))
        content.sizingOptions = []
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)

        panel.contentView = background
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.model.handleKey(event) ?? false }

        model.dismiss = { [weak self] in self?.hide() }
        model.isVisible = { [weak self] in self?.isVisible ?? false }
        engine.onChange = { [weak self] in self?.model.refresh() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        model.prepareForShow(frontmostPID: frontmost == .current ? nil : frontmost?.processIdentifier)
        position()
        #if DEBUG
        if debugQuiet {
            panel.level = .beneathDesktop
            panel.orderFrontRegardless()
            model.focus(.search)
            return
        }
        #endif
        panel.makeKeyAndOrderFront(nil)
        model.focus(.search)
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        model.reset()
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isPinned { hide() }
    }

    #if DEBUG
    /// Shows the panel beneath the desktop and without focus, so automated runs
    /// do not get in the way of whoever is using the Mac.
    var debugQuiet = false

    /// Feeds a key press such as "tab", "cmd+k" or "a" straight to the panel.
    func debugPress(_ token: String) {
        var flags: NSEvent.ModifierFlags = []
        var name = token
        for (prefix, flag) in [("cmd+", NSEvent.ModifierFlags.command), ("shift+", .shift), ("ctrl+", .control)] where name.hasPrefix(prefix) {
            flags.insert(flag)
            name.removeFirst(prefix.count)
        }
        let named: [String: (code: UInt16, characters: String)] = [
            "tab": (48, "\t"), "return": (36, "\r"), "escape": (53, "\u{1B}"),
            "down": (125, ""), "up": (126, ""), "space": (49, " "),
        ]
        let key = named[name] ?? (0, name)
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code
        ) else { return }
        if flags.contains(.command) {
            _ = panel.performKeyEquivalent(with: event)
        } else {
            panel.sendEvent(event)
        }
    }

    var debugState: String {
        "focus=\(model.focusTarget) responder=\(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") "
            + "query=\(model.query) selected=\(model.selectedID ?? "nil") arguments=\(model.argumentValues) "
            + "menu=\(model.isActionMenuOpen) route=\(model.route == nil ? "root" : "pushed")"
    }
    #endif

    /// Centered on the screen the pointer is on, a little above the middle.
    private func position() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }

        let size = LauncherMetrics.size
        let top = area.maxY - area.height * 0.2
        panel.setFrame(
            NSRect(x: area.midX - size.width / 2, y: max(area.minY, top - size.height), width: size.width, height: size.height),
            display: true
        )
    }
}
