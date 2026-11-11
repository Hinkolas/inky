import Foundation
import Observation

/// What the user decided about single commands: which are switched off, and
/// which have a hotkey. Kept as a JSON file, by the ids of their results.
///
/// A command is anything a module lists as a candidate: an application, a
/// quicklink, a system command. One that is off is not found, suggested or
/// offered as a fallback, and its hotkey does nothing. What is decided stays
/// here while the command is away, as when its module is switched off.
@MainActor
@Observable
public final class CommandStore {
    /// The ids of the commands that are switched off.
    public private(set) var disabled: Set<String> = []
    /// The hotkey of each command that has one, by its id.
    public private(set) var hotkeys: [String: KeyCombo] = [:]

    /// Called after a command was switched on or off, or its hotkey changed.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let fileURL: URL?

    private struct File: Codable {
        var disabled: [String]
        var hotkeys: [String: KeyCombo]
    }

    /// Pass nil to keep the choices in memory only. `initialHotkeys` are the
    /// hotkeys where there is no file yet.
    public init(fileURL: URL?, initialHotkeys: [String: KeyCombo] = [:]) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            if let file = try? JSONDecoder().decode(File.self, from: data) {
                disabled = Set(file.disabled)
                hotkeys = file.hotkeys
            }
        } else {
            hotkeys = initialHotkeys
            if !initialHotkeys.isEmpty { write() }
        }
    }

    public func isEnabled(_ id: String) -> Bool {
        !disabled.contains(id)
    }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        guard enabled != isEnabled(id) else { return }
        if enabled {
            disabled.remove(id)
        } else {
            disabled.insert(id)
        }
        didChange()
    }

    public func hotkey(for id: String) -> KeyCombo? {
        hotkeys[id]
    }

    /// Gives the command a hotkey, or takes it away with nil.
    public func setHotkey(_ combo: KeyCombo?, for id: String) {
        guard hotkeys[id] != combo else { return }
        hotkeys[id] = combo
        didChange()
    }

    /// The command that has this hotkey, if one does.
    public func command(with combo: KeyCombo) -> String? {
        // The same one every time, should a file edited by hand name two.
        hotkeys.filter { $0.value == combo }.keys.min()
    }

    /// Forgets what was decided about a command that is gone for good, such
    /// as a deleted quicklink.
    public func forget(_ id: String) {
        guard disabled.contains(id) || hotkeys[id] != nil else { return }
        disabled.remove(id)
        hotkeys[id] = nil
        didChange()
    }

    private func didChange() {
        write()
        onChange?()
    }

    private func write() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(File(disabled: disabled.sorted(), hotkeys: hotkeys)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
