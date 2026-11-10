import Foundation

public struct ProviderInfo: Sendable {
    public var title: String
    public var summary: String
    public var icon: Icon

    public init(title: String, summary: String, icon: Icon) {
        self.title = title
        self.summary = summary
        self.icon = icon
    }
}

/// A source of launcher results.
///
/// This is the contract every built-in feature is written against, and the one
/// scripted extensions will be hosted behind. A provider contributes results in
/// up to three ways, and implements only the ones it needs:
///
/// - `candidates` are indexed by the engine, which matches and ranks them
///   against the query. Use it for a known set of things: apps, commands, links.
/// - `instantResults` are computed from the query itself on every keystroke and
///   must return immediately. Use it for answers, such as a calculation.
/// - `deferredResults` may take time and arrive after the rest. Use it for
///   searches that leave the process, such as the file index.
@MainActor
public protocol Provider: AnyObject {
    var id: String { get }
    var info: ProviderInfo { get }

    /// Set by the engine. Call it when `candidates` would return something new.
    var onChange: (@MainActor () -> Void)? { get set }

    /// If set, the engine reloads `candidates` when the launcher opens and the
    /// last load is older than this.
    var refreshInterval: TimeInterval? { get }

    func candidates() async -> [ResultItem]
    func instantResults(for query: String) -> [ResultItem]
    func deferredResults(for query: String) async -> ResultSection?
}

public extension Provider {
    var refreshInterval: TimeInterval? { nil }
    func candidates() async -> [ResultItem] { [] }
    func instantResults(for query: String) -> [ResultItem] { [] }
    func deferredResults(for query: String) async -> ResultSection? { nil }
}
