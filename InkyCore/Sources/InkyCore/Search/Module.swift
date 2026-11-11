import Foundation

public struct ModuleInfo: Sendable {
    public var title: String
    public var summary: String
    public var icon: Icon

    public init(title: String, summary: String, icon: Icon) {
        self.title = title
        self.summary = summary
        self.icon = icon
    }
}

/// A self-contained part of Inky, such as the calculator or quicklinks.
///
/// This is the contract every built-in feature is written against, and the one
/// scripted extensions will be hosted behind: an extension is a module that
/// does not come with Inky. Today a module contributes results, in up to three
/// ways, and implements only the ones it needs:
///
/// - `candidates` are indexed by the engine, which matches and ranks them
///   against the query. Use it for a known set of things: apps, commands, links.
/// - `instantResults` are computed from the query itself on every keystroke and
///   must return immediately. Use it for answers, such as a calculation.
/// - `deferredResults` may take time and arrive after the rest. Use it for
///   searches that leave the process, such as the file index.
///
/// Every candidate is a command: the user can switch it off, and give it a
/// hotkey that runs its first action from anywhere, see `CommandStore`. The
/// module does nothing for this either.
///
/// A candidate that asks for exactly one argument is a command the user can
/// choose as a fallback, see `FallbackStore`. The launcher then offers it
/// below every search, and runs it with what was typed as that argument. The
/// module does nothing for this but declare the argument.
@MainActor
public protocol Module: AnyObject {
    var id: String { get }
    var info: ModuleInfo { get }

    /// Set by the engine. Call it when `candidates` would return something
    /// new, or when results that may be on screen are no longer right.
    var onChange: (@MainActor () -> Void)? { get set }

    /// If set, the engine reloads `candidates` when the launcher opens and the
    /// last load is older than this.
    var refreshInterval: TimeInterval? { get }

    func candidates() async -> [ResultItem]
    func instantResults(for query: String) -> [ResultItem]
    func deferredResults(for query: String) async -> ResultSection?
}

public extension Module {
    var refreshInterval: TimeInterval? { nil }
    func candidates() async -> [ResultItem] { [] }
    func instantResults(for query: String) -> [ResultItem] { [] }
    func deferredResults(for query: String) async -> ResultSection? { nil }
}
