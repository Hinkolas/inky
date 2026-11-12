import Foundation

/// Asks the network for a file.
public enum Download {
    /// What was answered: the bytes and the HTTP status.
    public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

    /// The most an answer may be. What Inky asks for, a website's icon or
    /// the day's exchange rates, is a few kilobytes; a server that sends
    /// more is not answering what was asked.
    public static let limit = 1 << 20

    /// Asks without cookies and without a cache of its own, and gives up on
    /// an answer longer than `limit` or slower than half a minute.
    public static let fetch: Fetch = { url in
        try await fetch(url, limit: limit, session: session)
    }

    /// Reads the answer as it arrives, and stops reading at `limit` bytes,
    /// rather than holding whatever the server sends before looking at it.
    static func fetch(_ url: URL, limit: Int, session: URLSession) async throws -> (data: Data, status: Int) {
        let (bytes, response) = try await session.bytes(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Said up front, it need not be read to be refused.
        guard response.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return (data, status)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
