import Foundation
import Observation

/// The icons of websites, fetched once and kept on disk.
///
/// Every host has one file named after it: the icon as it was answered, or
/// nothing if the source has none. The file's date is when it was asked for.
/// Fetching goes on whether or not the launcher is open, since the store
/// belongs to the app and not to a window.
@MainActor
@Observable
public final class FaviconStore {
    public struct Cached: Sendable, Hashable {
        public let url: URL
        public let fetched: Date
    }

    /// How far a refresh of every icon has come. It stays after the refresh
    /// has finished, to tell how it went.
    public struct Refresh: Sendable, Equatable {
        public var total: Int
        public var completed = 0
        /// Hosts that gave no answer. What was kept for them is unchanged.
        public var failed = 0

        public var isRunning: Bool { completed < total }
    }

    public var source: FaviconSource {
        didSet {
            guard source == .off else { return }
            // Nothing that was waiting may still be sent.
            let dropped = queue
            queue.removeAll()
            dropped.forEach { count($0, failed: true) }
        }
    }

    public private(set) var refresh: Refresh?

    private struct Entry {
        var fetched: Date
        var hasIcon: Bool
    }

    private enum Outcome: Sendable {
        case icon(Data)
        case noIcon
        case failed
    }

    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var active: Set<String> = []
    @ObservationIgnored private var refreshing: Set<String> = []
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let fetch: Favicon.Fetch

    static let iconLifetime: TimeInterval = 30 * 86_400
    /// A website without an icon is asked about again sooner: it may get one.
    static let missLifetime: TimeInterval = 7 * 86_400
    static let retryDelay: TimeInterval = 600
    private static let maxConcurrent = 6

    public init(directory: URL, source: FaviconSource = .duckDuckGo, fetch: @escaping Favicon.Fetch = Favicon.download) {
        self.directory = directory
        self.source = source
        self.fetch = fetch

        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [] {
            guard !file.lastPathComponent.hasPrefix("."),
                  let values = try? file.resourceValues(forKeys: keys),
                  let fetched = values.contentModificationDate, let size = values.fileSize
            else { continue }
            entries[file.lastPathComponent] = Entry(fetched: fetched, hasIcon: size > 0)
        }
    }

    /// How many icons are kept.
    public var iconCount: Int {
        entries.values.count { $0.hasIcon }
    }

    /// The icon kept for `host`, if there is one and icons are on.
    public func icon(for host: String) -> Cached? {
        guard source != .off, let entry = entries[host], entry.hasIcon else { return nil }
        return Cached(url: file(for: host), fetched: entry.fetched)
    }

    /// Fetches the icon of `host` unless a recent answer is kept. An icon that
    /// is kept stays in use until the new one has arrived.
    public func load(_ host: String, now: Date = .now) {
        guard source != .off else { return }
        if let entry = entries[host],
           now.timeIntervalSince(entry.fetched) < (entry.hasIcon ? Self.iconLifetime : Self.missLifetime) {
            return
        }
        if let retry = retryAfter[host], now < retry { return }
        enqueue(host)
    }

    /// Fetches every icon again: those that are kept, and those of `hosts`.
    public func refreshAll(including hosts: some Sequence<String> = [String]()) {
        guard source != .off, refresh?.isRunning != true else { return }
        let all = Set(entries.keys).union(hosts)
        guard !all.isEmpty else { return }
        refreshing = all
        refresh = Refresh(total: all.count)
        all.sorted().forEach(enqueue)
    }

    // MARK: - Private

    private func file(for host: String) -> URL {
        directory.appendingPathComponent(host, isDirectory: false)
    }

    private func enqueue(_ host: String) {
        guard !active.contains(host), !queue.contains(host) else { return }
        queue.append(host)
        pump()
    }

    private func pump() {
        while active.count < Self.maxConcurrent, !queue.isEmpty {
            let host = queue.removeFirst()
            guard let url = source.url(for: host) else {
                count(host, failed: true)
                continue
            }
            active.insert(host)
            Task { [fetch] in
                let outcome = await Self.outcome(of: fetch, url)
                finish(host, outcome)
            }
        }
    }

    private nonisolated static func outcome(of fetch: Favicon.Fetch, _ url: URL) async -> Outcome {
        guard let answer = try? await fetch(url) else { return .failed }
        switch answer.status {
        case 200: return Favicon.isImage(answer.data) ? .icon(answer.data) : .noIcon
        case 404, 410: return .noIcon
        default: return .failed
        }
    }

    private func finish(_ host: String, _ outcome: Outcome) {
        active.remove(host)
        var failed = false
        switch outcome {
        case .icon(let data):
            failed = !keep(data, for: host)
        case .noIcon:
            failed = !keep(Data(), for: host)
        case .failed:
            failed = true
        }
        if failed {
            retryAfter[host] = Date.now.addingTimeInterval(Self.retryDelay)
        } else {
            retryAfter[host] = nil
        }
        count(host, failed: failed)
        pump()
    }

    private func keep(_ data: Data, for host: String) -> Bool {
        do {
            try data.write(to: file(for: host), options: .atomic)
        } catch {
            return false
        }
        entries[host] = Entry(fetched: .now, hasIcon: !data.isEmpty)
        return true
    }

    /// Counts `host` towards the refresh, if it is part of one.
    private func count(_ host: String, failed: Bool) {
        guard refreshing.remove(host) != nil, var progress = refresh else { return }
        progress.completed += 1
        if failed { progress.failed += 1 }
        refresh = progress
    }
}
