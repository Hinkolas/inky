import Foundation
import Observation

/// The commands the launcher offers to send any search to, kept as a JSON
/// file of their ids.
///
/// Any result a module lists that asks for exactly one argument can be
/// chosen, see `ResultItem.canBeFallback`. A choice stays here while its
/// command is away, as when its module is switched off, so that the command
/// is a fallback again once it is back.
@MainActor
@Observable
public final class FallbackStore {
    /// The ids of the chosen results, first choice first.
    public private(set) var ids: [String]

    @ObservationIgnored private let fileURL: URL?

    /// Pass nil to keep the choice in memory only. `initial` is the choice
    /// where there is no file yet.
    public init(fileURL: URL?, initial: [String] = []) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            ids = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            ids = initial
            write()
        }
    }

    /// Makes the command the last choice.
    public func add(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        write()
    }

    public func remove(_ id: String) {
        guard ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        write()
    }

    /// Moves a command up (negative) or down among `listed`, the choices the
    /// user can see.
    public func move(_ id: String, by offset: Int, among listed: [String]) {
        // The listed ones trade places with each other; the choices between
        // them, whose commands are away, stay where they are.
        let listed = Set(listed)
        let slots = ids.indices.filter { listed.contains(ids[$0]) }
        guard let position = slots.firstIndex(where: { ids[$0] == id }),
              slots.indices.contains(position + offset), offset != 0
        else { return }
        var moved = slots.map { ids[$0] }
        moved.insert(moved.remove(at: position), at: position + offset)
        for (slot, id) in zip(slots, moved) {
            ids[slot] = id
        }
        write()
    }

    private func write() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(ids) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
