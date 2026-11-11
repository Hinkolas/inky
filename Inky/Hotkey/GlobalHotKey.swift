import AppKit
import Carbon.HIToolbox
import InkyCore

extension KeyCombo {
    static let defaultLauncher = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags.option.rawValue)

    init(event: NSEvent) {
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
        )
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }

    /// The glyphs to draw as keycaps, modifiers first.
    var symbols: [String] {
        var symbols: [String] = []
        if flags.contains(.control) { symbols.append("⌃") }
        if flags.contains(.option) { symbols.append("⌥") }
        if flags.contains(.shift) { symbols.append("⇧") }
        if flags.contains(.command) { symbols.append("⌘") }
        symbols.append(Self.keyName(for: keyCode))
        return symbols
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↵", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The label printed on the key in the user's keyboard layout.
    private static func keyName(for keyCode: UInt32) -> String {
        if let name = namedKeys[Int(keyCode)] { return name }

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let layout = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes in
            UCKeyTranslate(
                bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// A system-wide hotkey. Uses the Carbon hotkey API, which is the one way to
/// do this that needs no Accessibility permission.
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var isDispatcherInstalled = false

    private let id: UInt32
    private var reference: EventHotKeyRef?

    /// Returns nil if the system refuses the combination.
    init?(_ combo: KeyCombo, handler: @escaping () -> Void) {
        Self.installDispatcher()
        id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x494E_4B59), id: id) // "INKY"
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.handlers[id] = nil
    }

    private static func installDispatcher() {
        guard !isDispatcherInstalled else { return }
        isDispatcherInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyPressed, 1, &eventType, nil, nil)
    }

    fileprivate static func fire(_ id: UInt32) {
        handlers[id]?()
    }
}

/// Carbon calls this on the main thread.
private nonisolated func hotKeyPressed(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        GlobalHotKey.fire(id)
    }
    return noErr
}
