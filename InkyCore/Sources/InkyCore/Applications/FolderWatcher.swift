import CoreServices
import Foundation

/// Says when something changed in folders, or anywhere below them. Changes
/// that come close together are said once, after `latency` seconds.
///
/// A folder may not be there yet, or be replaced: what happens in it is then
/// said from when it is there.
@MainActor
final class FolderWatcher {
    private let paths: [String]
    private let latency: TimeInterval
    private let onChange: @MainActor () -> Void
    private nonisolated(unsafe) var stream: FSEventStreamRef?

    init(_ paths: [String], latency: TimeInterval = 2, onChange: @escaping @MainActor () -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
        start()
    }

    deinit {
        Self.stop(stream)
    }

    private func start() {
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info else { return }
            let rootChanged = UnsafeBufferPointer(start: flags, count: count).contains {
                $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
            }
            // Delivered on the main queue, see below.
            MainActor.assumeIsolated {
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().didChange(rootChanged: rootChanged)
            }
        }
        // Watching the way to each folder too says when it comes or goes.
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func didChange(rootChanged: Bool) {
        if rootChanged {
            // What is in a folder that came is only said once it is
            // watched as it is now. Not from within the stream's own call.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Self.stop(stream)
                stream = nil
                start()
            }
        }
        onChange()
    }

    private nonisolated static func stop(_ stream: FSEventStreamRef?) {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
