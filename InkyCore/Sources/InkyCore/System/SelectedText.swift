import ApplicationServices
import Foundation

/// Reads the text selected in another app through the Accessibility API.
public enum SelectedText {
    /// Whether the user has granted Inky Accessibility access.
    public static var hasAccess: Bool {
        AXIsProcessTrusted()
    }

    /// Returns the selection in the app with `pid`, or nil if there is none.
    /// Without Accessibility access this asks the user for it and returns nil.
    @MainActor
    public static func read(from pid: pid_t?) -> String? {
        guard hasAccess else {
            let prompt = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            return nil
        }
        guard let pid else { return nil }

        let app = AXUIElementCreateApplication(pid)
        // An unresponsive app must not hang the launcher.
        AXUIElementSetMessagingTimeout(app, 0.5)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }

        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selection) == .success,
              let text = selection as? String, !text.isEmpty
        else { return nil }
        return text
    }
}

public enum AppSupport {
    /// Where Inky keeps its data: ~/Library/Application Support/Inky.
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Inky", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Where Inky keeps what it can fetch again: ~/Library/Caches/Inky.
    public static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Inky", isDirectory: true)
    }
}
