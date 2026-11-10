import AppKit
import InkyCore
import SwiftUI

/// The floating window. It takes keyboard focus without activating Inky, so
/// the app the user was in stays frontmost and gets focus back on dismissal.
///
/// The window itself is an invisible canvas, large enough for the biggest
/// command. The bar and cards float on it, each with its own blur and shadow.
final class LauncherPanel: NSPanel {
    /// Sees every key press before the focused text field. Returns true to consume it.
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: LauncherMetrics.canvas),
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
        // The floating parts draw their own shadows.
        hasShadow = false
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

        let content = NSHostingView(rootView: LauncherView(model: model))
        content.sizingOptions = []
        panel.contentView = content
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
            debugBackdrop?.setFrame(panel.frame, display: true)
            debugBackdrop?.orderFrontRegardless()
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
        #if DEBUG
        debugBackdrop?.orderOut(nil)
        #endif
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
        let route = model.routes.map { route in
            switch route {
            case .quicklinks(let browser):
                "quicklinks(filter=\(browser.filter) query=\(browser.query) selected=\(browser.selected?.name ?? "nil") visible=\(browser.visible.count))"
            case .quicklinkEditor(let draft):
                "editor(\(draft.isNew ? "new" : draft.name))"
            }
        }
        return "focus=\(model.focusTarget) responder=\(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") "
            + "query=\(model.query) results=\(model.showsResults) sections=\(model.sections.map { "\($0.title):\($0.items.count)" }) "
            + "selected=\(model.selectedID ?? "nil") arguments=\(model.argumentValues) "
            + "menu=\(model.isActionMenuOpen ? "\(model.actionMenuIndex)" : "closed") route=\(route.isEmpty ? "root" : route.joined(separator: " > ")) "
            + "toast=\(model.toast ?? "nil") appearance=\(panel.effectiveAppearance.name.rawValue)"
    }

    /// A stand-in wallpaper, drawn behind the panel in quiet mode so captures
    /// show how the surfaces take on what is behind them.
    private var debugBackdrop: NSWindow?

    func debugShowBackdrop(dark: Bool) {
        let window = NSWindow(contentRect: panel.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.beneathDesktop.rawValue - 1)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = DebugBackdropView(dark: dark)
        debugBackdrop = window
    }
    #endif

    /// On the screen the pointer is on, with the bar a little under a quarter
    /// of the way down.
    private func position() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }

        let canvas = LauncherMetrics.canvas
        let margin = LauncherMetrics.margin
        // The top of the bar.
        var top = area.maxY - area.height * 0.24
        // On a small screen, move up until the tallest command fits.
        top = max(top, area.minY + 12 + LauncherMetrics.maxContentSize.height)
        top = min(top, area.maxY - 8)
        panel.setFrame(
            NSRect(x: area.midX - canvas.width / 2, y: top + margin.top - canvas.height, width: canvas.width, height: canvas.height),
            display: true
        )
    }
}

#if DEBUG
/// Shapes and gradients with enough going on to judge a blur by.
private final class DebugBackdropView: NSView {
    private let dark: Bool

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size

        func glow(_ color: NSColor, x: CGFloat, y: CGFloat, radius: CGFloat) {
            let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
            let center = CGPoint(x: size.width * x, y: size.height * y)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size.width * radius, options: [])
        }

        if dark {
            NSColor.hex(0x0A0F1F).setFill()
            bounds.fill()
            glow(.hex(0x3A2BD6), x: 0.14, y: 0.78, radius: 0.34)
            glow(.hex(0x0E8A8F), x: 0.92, y: 0.08, radius: 0.36)

            let disc = CGRect(x: size.width * 0.42, y: size.height * 0.22, width: size.width * 0.4, height: size.width * 0.4)
            context.saveGState()
            context.addEllipse(in: disc)
            context.clip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [NSColor.hex(0xFF7A59).cgColor, NSColor.hex(0xFF3D7F).cgColor, NSColor.hex(0xB02ACB).cgColor] as CFArray,
                locations: [0, 0.55, 1]
            ) {
                context.drawLinearGradient(gradient, start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
            }
            context.restoreGState()

            context.setStrokeColor(NSColor.hex(0x2AB3A6).cgColor)
            context.setLineWidth(size.width * 0.032)
            context.strokeEllipse(in: CGRect(x: size.width * 0.7, y: size.height * 0.5, width: size.width * 0.5, height: size.width * 0.5))

            context.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(1)
            for index in 0..<60 {
                let x = CGFloat(index) * size.width / 58
                let y = size.height * 0.2 + x * 0.26
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x + 14, y: y + size.height * 0.16))
            }
            context.strokePath()
        } else {
            NSColor.hex(0xCBD5F2).setFill()
            bounds.fill()
            glow(.hex(0x8DAEFB), x: 0.12, y: 0.82, radius: 0.42)
            glow(.hex(0xB9A6FF), x: 0.72, y: 0.92, radius: 0.36)
            glow(.hex(0xF4B5A2), x: 0.88, y: 0.1, radius: 0.38)

            context.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            context.fillEllipse(in: CGRect(x: -size.width * 0.2, y: -size.height * 0.75, width: size.width * 1.3, height: size.height * 1.3))
        }
    }
}
#endif
