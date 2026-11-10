import Foundation
import ImageIO

/// Where website icons come from.
public enum FaviconSource: String, Sendable, CaseIterable, Identifiable {
    case duckDuckGo
    /// No requests are made and no website icons are shown.
    case off

    public var id: Self { self }

    public var title: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .off: "None"
        }
    }

    /// Where the icon of `host` is asked for. The host is all that is sent.
    func url(for host: String) -> URL? {
        switch self {
        case .duckDuckGo: URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
        case .off: nil
        }
    }
}

public enum Favicon {
    /// What a source answered: the bytes and the HTTP status.
    public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

    /// The public website a link goes to. Nil for a folder, an app link, a
    /// link whose host is a placeholder, and a host on the user's own network,
    /// which no outside service should hear about.
    public static func host(of link: String) -> String? {
        var text = Substring(link.trimmingCharacters(in: .whitespaces))
        guard !text.hasPrefix("/"), !text.hasPrefix("~") else { return nil }

        if let scheme = text.firstMatch(of: /^([A-Za-z][A-Za-z0-9+.-]*):/) {
            let rest = text[scheme.range.upperBound...]
            guard ["http", "https"].contains(scheme.1.lowercased()), rest.hasPrefix("//") else { return nil }
            text = rest.dropFirst(2)
        }

        // The host ends where the path, the query or a placeholder begins.
        var authority = text.prefix { !"/?#{".contains($0) }
        // A placeholder inside the host: what it will be is not known yet.
        guard text.dropFirst(authority.count).first != "{" else { return nil }
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        if let port = authority.firstIndex(of: ":") {
            authority = authority[..<port]
        }
        if authority.hasSuffix(".") {
            authority = authority.dropLast()
        }

        // Turns a name in another script into the ASCII form it is looked up by.
        var components = URLComponents()
        components.host = String(authority)
        guard let host = components.encodedHost?.lowercased() else { return nil }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let isName = labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        guard isName, labels.count > 1, let last = labels.last,
              // An address rather than a name.
              !last.allSatisfy(\.isNumber),
              !localSuffixes.contains(String(last))
        else { return nil }
        return host
    }

    /// Endings of names that only mean something on a local network.
    private static let localSuffixes: Set<String> = [
        "local", "localhost", "internal", "intranet", "lan", "home", "corp", "private",
        "test", "invalid", "example", "arpa",
    ]

    /// Asks the network, without cookies and without a cache of its own.
    public static let download: Fetch = { url in
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

    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
