import Foundation

/// Asks the network for a file.
public enum Download {
    /// What was answered: the bytes and the HTTP status.
    public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

    /// Asks without cookies and without a cache of its own.
    public static let fetch: Fetch = { url in
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
