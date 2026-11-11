import Foundation

/// A key plus modifiers, pressed anywhere on the Mac: the hotkey that opens
/// Inky, or one that runs a command.
public struct KeyCombo: Codable, Hashable, Sendable {
    /// The key's position on the keyboard, as macOS numbers them.
    public var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, limited to ⌘⌥⌃⇧.
    public var modifiers: UInt

    public init(keyCode: UInt32, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
