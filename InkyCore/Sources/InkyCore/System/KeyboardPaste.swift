import AppKit
import Carbon.HIToolbox

/// Presses ⌘V for the user, to paste into the application they are in.
public enum KeyboardPaste {
    /// Whether macOS lets Inky press keys, which takes Accessibility access.
    public static var isAllowed: Bool {
        AXIsProcessTrusted()
    }

    /// Has macOS ask the user for Accessibility access.
    public static func requestAccess() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Pastes into `target`, the application the user asked to paste into.
    /// ⌘V goes to whichever application is in front, so nothing is pressed
    /// unless that is still `target`: what is pasted may be a password, and
    /// another application that came forward meanwhile is not to have it.
    /// Returns false if nothing was pressed, also when Inky may not press keys.
    @MainActor
    @discardableResult
    public static func paste(into target: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target, isAllowed else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys pressed for someone hold their own back for a moment unless
        // told otherwise, and what they type right after pasting would be lost.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let key = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        // Only Command, whatever else is still held from the keys that asked for this.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// The key that types `character` with Command held, in the user's
    /// keyboard layout. On most it is where the letter is printed; on one
    /// such as Dvorak it is not, and some layouts move back while Command
    /// is down.
    @MainActor
    static func keyCode(for character: String) -> CGKeyCode? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let command = UInt32(cmdKey >> 8) & 0xFF

        return layout.withUnsafeBytes { bytes -> CGKeyCode? in
            let keyboard = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress
            // The usual place first, so that it wins over a key that types the same.
            for code in [UInt16(kVK_ANSI_V)] + Array(0..<UInt16(127)) {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    keyboard, code, UInt16(kUCKeyActionDown), command, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
                )
                if status == noErr, length > 0,
                   String(utf16CodeUnits: characters, count: length).lowercased() == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
