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
/// does not come with Inky. Today a module contributes results, in up to four
/// ways, and implements only the ones it needs:
///
/// - `candidates` are indexed by the engine, which matches and ranks them
///   against the query. Use it for a known set of things: apps, commands, links.
/// - `instantResults` are computed from the query itself on every keystroke and
///   must return immediately. Use it for answers, such as a calculation.
/// - `deferredResults` may take time and arrive after the rest. Use it for
///   searches that leave the process, such as the file index.
/// - `fallbackResults` take the query somewhere else. They are offered below
///   everything that was found, and are all there is when nothing was. Like
///   instant results they must return immediately.
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
    func fallbackResults(for query: String) -> [ResultItem]
}

public extension Module {
    var refreshInterval: TimeInterval? { nil }
    func candidates() async -> [ResultItem] { [] }
    func instantResults(for query: String) -> [ResultItem] { [] }
    func deferredResults(for query: String) async -> ResultSection? { nil }
    func fallbackResults(for query: String) -> [ResultItem] { [] }
}
