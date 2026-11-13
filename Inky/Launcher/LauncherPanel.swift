import AppKit
import Carbon.HIToolbox
import InkyCore
import QuartzCore
import SwiftUI

/// The floating window. It takes keyboard focus without activating Inky, so
/// the app the user was in stays frontmost and gets focus back on dismissal.
///
/// The window itself is an invisible canvas, large enough for the biggest
/// command. The bar and cards float on it, each with its own blur and shadow.
final class LauncherPanel: NSPanel {
    /// Sees every key press before the focused text field. Returns true to consume it.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Called before a key press or a click goes anywhere, while there is
    /// still time to see that typing has somewhere to go.
    var inputWillArrive: ((NSEvent) -> Void)?

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

    #if DEBUG
    /// In a run that takes the keyboard while hidden, what the user types
    /// meanwhile must not do anything here. Only the run's own keys count.
    var debugIgnoresTyping = false
    var debugIsPressing = false
    /// F20, which nothing uses: pressed to see whether typing arrives here.
    static let debugProbeKey: UInt16 = 0x5A
    var debugProbeArrived = false
    #endif

    override func sendEvent(_ event: NSEvent) {
        #if DEBUG
        if event.type == .keyDown || event.type == .keyUp {
            if event.keyCode == Self.debugProbeKey {
                debugProbeArrived = true
                return
            }
            if debugIgnoresTyping, !debugIsPressing { return }
        }
        #endif
        switch event.type {
        case .keyDown:
            inputWillArrive?(event)
            if handle(event) { return }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            inputWillArrive?(event)
        default:
            break
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        #if DEBUG
        if event.keyCode == Self.debugProbeKey {
            debugProbeArrived = true
            return true
        }
        if debugIgnoresTyping, !debugIsPressing { return true }
        #endif
        inputWillArrive?(event)
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
    /// For how many seconds a launcher that was put away opens again as it
    /// was left. With none, it never does.
    var resumesWithin: () -> TimeInterval = { 0 }

    private let panel = LauncherPanel()
    /// True while the panel fades out. It is still on screen, but gone as
    /// far as anyone using it is concerned.
    private var isClosing = false
    /// Tells a fade that ran to its end from one that was cut short.
    private var closeCount = 0
    /// What waits for the panel to be gone.
    private var afterHiding: [() -> Void] = []
    /// Whether the panel, as it closes, keeps what it shows.
    private var keepsState = false
    /// When the panel was put away with what it showed still in it. Nil
    /// while it is up, and once it was closed for good.
    private var setAsideAt: Date?
    /// True while the keyboard goes back to where it was in a launcher
    /// that opens as it was left. What is in that field is added to.
    private var isResumingFocus = false

    init(
        engine: SearchEngine,
        quicklinks: QuicklinkStore,
        uninstaller: ApplicationUninstaller,
        clipboard: ClipboardHistory,
        history: InputHistory
    ) {
        model = LauncherModel(
            engine: engine, quicklinks: quicklinks, uninstaller: uninstaller, clipboard: clipboard, history: history
        )
        super.init()

        let content = NSHostingView(rootView: LauncherView(model: model))
        content.sizingOptions = []
        panel.contentView = content
        panel.delegate = self
        panel.keyHandler = { [weak self] event in
            guard let self else { return false }
            // Keys pressed while it fades out are not meant for it anymore.
            return isClosing || model.handleKey(event)
        }
        panel.inputWillArrive = { [weak self] event in self?.inputWillArrive(event) }
        model.focusDidChange = { [weak self] in self?.settleFocus() }

        model.dismiss = { [weak self] in self?.hide() }
        model.setAside = { [weak self] in self?.hide(resumable: true) }
        model.dismissThen = { [weak self] action in
            if let self { hide(then: action) } else { action() }
        }
        model.isVisible = { [weak self] in self?.isVisible ?? false }
        engine.onChange = { [weak self] in self?.model.refresh() }
    }

    var isVisible: Bool { panel.isVisible && !isClosing }

    /// What Inky's hotkey does. Pressed again, it puts the launcher away
    /// the way a click elsewhere does.
    func toggle() {
        if isVisible { hide(resumable: true) } else { show() }
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        // Asked for again before it had faded out: start over.
        if isClosing { finishHiding() }
        let isOpening = !panel.isVisible
        let motion = Motion.current
        let isResuming = resume()

        model.prepareForShow(
            frontmostPID: frontmost == .current ? nil : frontmost?.processIdentifier,
            resuming: isResuming
        )
        position()
        if isOpening, motion.level != .off { panel.alphaValue = 0 }
        #if DEBUG
        if debugQuiet {
            panel.level = .beneathDesktop
            debugBackdrop?.setFrame(panel.frame, display: true)
            debugBackdrop?.orderFrontRegardless()
            if debugTakesKeyboard {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        #else
        panel.makeKeyAndOrderFront(nil)
        #endif
        if isResuming {
            // Where it was: that can be an argument.
            isResumingFocus = true
            model.focus(model.focusTarget)
        } else {
            // The search, or the screen that is showing if the launcher was open.
            model.focusDefault()
        }
        if isOpening { animateIn(motion) }
    }

    /// Whether the launcher was put away with something in it, and not
    /// too long ago to open with it again.
    private var canResume: Bool {
        setAsideAt.map { Date.now.timeIntervalSince($0) < resumesWithin() } ?? false
    }

    /// Takes up what the launcher was put away with, and says whether
    /// there was anything. What was put away too long ago goes, the way it
    /// does when the launcher is closed.
    private func resume() -> Bool {
        guard canResume else {
            discardState()
            return false
        }
        setAsideAt = nil
        return true
    }

    /// Lets go of what a launcher that is not up was put away with.
    private func discardState() {
        // Still on its way out: it is not to keep anything once it is gone.
        keepsState = false
        guard setAsideAt != nil else { return }
        setAsideAt = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.reset() }
    }

    /// Runs a command as its hotkey does. Most are simply run, wherever the
    /// user is. One that opens a screen in the launcher, or asks for
    /// arguments, shows the launcher with it, whatever the launcher was
    /// showing, or closes the launcher if that is what it shows.
    func run(_ item: ResultItem) {
        guard model.opensLauncher(item) else {
            let frontmost = NSWorkspace.shared.frontmostApplication
            model.run(item, frontmostPID: frontmost == .current ? nil : frontmost?.processIdentifier)
            return
        }
        if isVisible, model.isShowing(item) {
            hide()
            return
        }
        if isClosing { finishHiding() }
        let wasVisible = isVisible
        if !wasVisible, setAsideAt != nil {
            // Put away showing just this, it opens again as it was.
            if canResume, model.isShowing(item) {
                show()
                return
            }
            // Anything else goes, as it would have gone under the command.
            discardState()
        }
        show()
        // Opened straight to it, a screen is simply there. From the search
        // it is a change of screen like any other.
        model.open(item, instantly: !wasVisible)
    }

    /// Closes the panel. `action` runs once it is off screen, when keys go
    /// to the application behind it again.
    ///
    /// Closed like this, the launcher starts anew the next time. `resumable`
    /// puts it away as it is, to open again where it was left: for a click
    /// elsewhere or the hotkey, which say nothing about being done.
    func hide(then action: (() -> Void)? = nil, resumable: Bool = false) {
        guard isVisible else {
            // Closing for good counts for more than putting away. Running
            // something that takes the keyboard does both, in either order.
            if !resumable { discardState() }
            // Already on its way out, or not there at all.
            if let action {
                if isClosing { afterHiding.append(action) } else { action() }
            }
            return
        }
        if let action { afterHiding.append(action) }
        keepsState = resumable
        let motion = Motion.current
        guard motion.level != .off else {
            finishHiding()
            return
        }

        isClosing = true
        let count = closeCount
        fade(to: 0, duration: motion.seconds(Self.closeDuration), timing: .easeIn) { [weak self] in
            guard let self, isClosing, count == closeCount else { return }
            finishHiding()
        }
        if motion.level == .full {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.toValue = scale(Self.closedScale)
            animation.duration = motion.seconds(Self.closeDuration)
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Stays small until the panel is off screen.
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            panel.contentView?.layer?.add(animation, forKey: Self.scaleKey)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isPinned { hide(resumable: true) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        settleFocus()
    }

    // MARK: - Focus

    // The model says which field is typed into. This puts the keyboard
    // there, which SwiftUI cannot be relied on to do: see LauncherFocus.swift.

    /// Counts the times the keyboard was asked somewhere, so that seeing to
    /// one request ends where the next begins.
    private var focusRequest = 0
    /// The keyboard is looked after for a moment once it was asked
    /// somewhere: right away, which does it if the field is there, and then
    /// again after each of these waits, in seconds. The next turns of the
    /// run loop are when SwiftUI has made a field that was not there yet.
    /// The later looks are for anything but the user moving the keyboard
    /// away again while a window or a screen settles in.
    private static let focusWaits: [TimeInterval] = [0, 0, 0.02, 0.03, 0.05, 0.1]
    /// The look by which a field that is going to be there, is.
    private static let focusFallbackLook = 3

    /// Whether the panel is to have the keyboard while it is up.
    private var takesKeyboard: Bool {
        #if DEBUG
        if debugQuiet { return debugTakesKeyboard }
        #endif
        return true
    }

    /// Puts the keyboard where the model wants it, and sees that it stays.
    private func settleFocus() {
        focusRequest += 1
        model.isFocusSettling = true
        settleFocus(focusRequest, look: 0)
    }

    private func settleFocus(_ request: Int, look: Int) {
        guard request == focusRequest else { return }
        guard isVisible else {
            endSettlingFocus()
            return
        }
        // Up, and not pinned open: it is the window that is typed into.
        if takesKeyboard, !isPinned, !panel.isKeyWindow { panel.makeKey() }
        // Still not there after SwiftUI had its turns to make the field:
        // it is not going to be found. SwiftUI knows its own.
        if !placeFocus(), look == Self.focusFallbackLook { model.focusBySwiftUI() }

        guard look < Self.focusWaits.count else {
            endSettlingFocus()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusWaits[look]) { [weak self] in
            self?.settleFocus(request, look: look + 1)
        }
    }

    /// Gives the keyboard to the field the model wants it in. False if that
    /// field is not there, which it is not until SwiftUI has made it.
    @discardableResult
    private func placeFocus() -> Bool {
        guard let target = model.focusTarget else { return true }
        guard let field = panel.contentView?.textField(for: target) else { return false }
        // Typed into already: what is selected in it stays as it is.
        if let editor = field.currentEditor(), panel.firstResponder === editor { return true }
        guard panel.makeFirstResponder(field) else { return false }
        // A field that takes the keyboard selects what it holds, to be typed
        // over. A link is added to more often than it is replaced, and so
        // is what was being typed when the launcher was put away.
        if target == .quicklinkLink || isResumingFocus, let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
        return true
    }

    /// From here on the keyboard is where the user puts it.
    private func endSettlingFocus() {
        focusRequest += 1
        model.isFocusSettling = false
        isResumingFocus = false
    }

    private func inputWillArrive(_ event: NSEvent) {
        guard isVisible else { return }
        if event.type == .keyDown {
            // With no field at all, as when the one that had the keyboard
            // went away, it goes where it belongs first, so that nothing
            // typed is lost.
            if panel.firstResponder === panel { placeFocus() }
            // Tab moves the keyboard, as a click does. Other keys are typed.
            guard Int(event.keyCode) == kVK_Tab else { return }
        }
        // The user is about to move the keyboard themselves. Once it has
        // got where it was asked, that is theirs to do.
        if model.isFocusSettling, placeFocus() { endSettlingFocus() }
    }

    // MARK: - Opening and closing

    // The panel fades as a whole, which a window can do with everything in
    // it, blur included. On top of that its content grows into place from
    // around the bar, and gives a little on the way out. Opening has to feel
    // instant: the panel takes keys from the first frame.

    private static let openDuration = 0.16
    private static let closeDuration = 0.11
    private static let openedScale = 0.96
    private static let closedScale = 0.985
    private static let scaleKey = "inky.launcher.scale"

    private func animateIn(_ motion: Motion) {
        guard motion.level != .off else { return }
        fade(to: 1, duration: motion.seconds(Self.openDuration), timing: .easeOut)

        guard motion.level == .full, let layer = panel.contentView?.layer else { return }
        let animation = CASpringAnimation(perceptualDuration: motion.seconds(0.3), bounce: 0.18)
        animation.keyPath = "transform"
        animation.fromValue = scale(Self.openedScale)
        animation.toValue = CATransform3DIdentity
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: Self.scaleKey)
    }

    private func finishHiding() {
        isClosing = false
        closeCount += 1
        panel.orderOut(nil)
        panel.contentView?.layer?.removeAnimation(forKey: Self.scaleKey)
        fade(to: 1, duration: 0, timing: .linear)
        #if DEBUG
        debugBackdrop?.orderOut(nil)
        #endif
        let keeps = keepsState && model.hasSomethingToResume && resumesWithin() > 0
        keepsState = false
        setAsideAt = keeps ? .now : nil
        // Nobody is looking, and a change left half-animated would finish
        // in front of the user the next time the panel opens.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if keeps { model.suspend() } else { model.reset() }
        }

        let actions = afterHiding
        afterHiding = []
        for action in actions {
            action()
        }
    }

    private func fade(
        to alpha: CGFloat,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    /// The content scaled around the middle of the bar, so that the bar
    /// stays where it is.
    private func scale(_ scale: CGFloat) -> CATransform3D {
        guard let view = panel.contentView, let layer = view.layer else { return CATransform3DIdentity }
        let barMiddle = LauncherMetrics.margin.top + LauncherMetrics.barHeight / 2
        // A layer's transform is about its anchor point.
        let anchor = CGPoint(
            x: layer.bounds.minX + layer.bounds.width * layer.anchorPoint.x,
            y: layer.bounds.minY + layer.bounds.height * layer.anchorPoint.y
        )
        let x = view.bounds.midX - anchor.x
        // Measured from the bottom, whichever way up the view counts.
        let y = view.bounds.height - barMiddle - anchor.y
        var transform = CATransform3DMakeTranslation(x, y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -x, -y, 0)
    }

    #if DEBUG
    /// Shows the panel beneath the desktop and without focus, so automated runs
    /// do not get in the way of whoever is using the Mac.
    var debugQuiet = false

    /// Has a quiet run take the keyboard as the launcher really does, still
    /// hidden: where focus ends up depends on the panel being the key window.
    /// What the user types meanwhile is dropped instead of acted on.
    var debugTakesKeyboard = false {
        didSet { panel.debugIgnoresTyping = debugTakesKeyboard }
    }

    /// Takes the keyboard away from whichever field has it, as nothing
    /// should, to see that it comes back.
    func debugBlur() {
        panel.makeFirstResponder(nil)
    }

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
        panel.debugIsPressing = true
        defer { panel.debugIsPressing = false }
        if flags.contains(.command) {
            _ = panel.performKeyEquivalent(with: event)
        } else {
            panel.sendEvent(event)
        }
    }

    /// Presses F20, a key nothing uses, the way a keyboard does, and says
    /// whether it arrived at the panel: whether typing really lands here.
    func debugProbe() async -> Bool {
        panel.debugProbeArrived = false
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: LauncherPanel.debugProbeKey, keyDown: isDown)?
                .post(tap: .cgSessionEventTap)
        }
        for _ in 0..<20 where !panel.debugProbeArrived {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return panel.debugProbeArrived
    }

    var debugState: String {
        let route = model.routes.map { route in
            switch route {
            case .quicklinks(let browser):
                "quicklinks(filter=\(browser.filter) query=\(browser.query) selected=\(browser.selected?.name ?? "nil") visible=\(browser.visible.count))"
            case .quicklinkEditor(let draft):
                "editor(\(draft.isNew ? "new" : draft.name))"
            case .uninstallBrowser(let browser):
                "uninstall(query=\(browser.query) selected=\(browser.selected?.name ?? "nil") visible=\(browser.visible.count))"
            case .uninstall(let review):
                // A minus marks what is unticked.
                "uninstall(\(review.app.name) cursor=\((review.cursor as NSString).lastPathComponent) "
                    + "items=\(review.items.map { review.isChosen($0) ? $0.name : "-" + $0.name }) summary=\(review.summary))"
            case .clipboard(let browser):
                "clipboard(filter=\(browser.filter) range=\(browser.range) query=\(browser.query) "
                    + "selected=\(browser.selected?.displayTitle ?? "nil") listed=\(browser.clips.count) "
                    + "pins=\(browser.snapshot.pins.count) total=\(browser.snapshot.total) "
                    + "renaming=\(browser.renaming ?? "nil") "
                    + "actions=\(browser.selected.map { model.actions(for: $0, in: browser).map(\.title) } ?? []))"
            case .files(let browser):
                "files(filter=\(browser.filter) query=\(browser.query) recents=\(browser.listed.isRecents) "
                    + "selected=\(browser.selected?.name ?? "nil") listed=\(browser.files.count) "
                    + "preview=\(browser.selected.flatMap(browser.preview(of:))?.debugName ?? "nil"))"
            }
        }
        // The field that has the keyboard, told by its placeholder, with what
        // is typed and selected in it.
        let editor = panel.firstResponder as? NSTextView
        let field = (editor?.delegate as? NSTextField).map { $0.placeholderString ?? $0.placeholderAttributedString?.string ?? "?" }
        let responder = editor.map { "\(field ?? "editor")<\($0.string)>\($0.selectedRange())" }
            ?? panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "history=\(model.history.entries.count) recall=\(model.debugRecallIndex.map(String.init) ?? "none") "
            + "kept=\(setAsideAt != nil) "
            + "focus=\(model.focusTarget.map { "\($0)" } ?? "none") key=\(panel.isKeyWindow) visible=\(isVisible) responder=\(responder) "
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
