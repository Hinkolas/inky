import Foundation

/// A web address the way it is typed into a browser: "amazon.com",
/// "github.com/hinkolas/inky", "localhost:3000", "https://example.com/a?b=c".
///
/// It errs on the side of being one. Whatever ends in a top-level domain
/// counts, so "main.rs" does too: Serbia's domain is as real as a Rust file,
/// and the file is still listed below.
public struct WebAddress: Sendable, Hashable {
    /// What the browser is given: the address, with the scheme it was typed
    /// without.
    public let url: URL

    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= Self.longest, !text.contains(where: \.isWhitespace) else { return nil }

        // Spelled out in full, it goes wherever it says: a name on the local
        // network, an address, a host with a login.
        if text.prefixMatch(of: /https?:\/\//.ignoresCase()) != nil {
            guard let url = URL(string: text), let host = url.host(), !host.isEmpty else { return nil }
            self.url = url
            return
        }

        // The host ends where the path, the query or the fragment begins.
        var host = text.prefix { !"/?#".contains($0) }
        // "name@example.com" is someone's mail, not a page.
        guard !host.contains("@") else { return nil }
        // What follows a colon is a port. This leaves out every other kind of
        // link as well: "mailto:", "slack://" and "file:///" have none.
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(port), (1...65535).contains(number)
            else { return nil }
            host = host[..<colon]
        }

        // What runs on this Mac or is reached by its address is rarely served
        // securely. Everything else is.
        let scheme: String
        if host.lowercased() == "localhost" || Self.isAddress(host) {
            scheme = "http"
        } else if Self.isDomain(host) {
            scheme = "https"
        } else {
            return nil
        }
        guard let url = URL(string: scheme + "://" + text) else { return nil }
        self.url = url
    }

    /// Longer than any address that is typed, and short enough to look at on
    /// every keystroke.
    private static let longest = 2048

    /// Four numbers up to 255, as in "192.168.0.1".
    private static func isAddress(_ host: Substring) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber } && UInt8(part) != nil
        }
    }

    /// At least two names with dots between them, the last of them a
    /// top-level domain.
    private static func isDomain(_ host: Substring) -> Bool {
        // Turns a name in another script into the ASCII form it is looked up
        // by, which is also how the top-level domains are listed.
        var components = URLComponents()
        components.host = String(host)
        guard let encoded = components.encodedHost?.lowercased() else { return false }

        let labels = encoded.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, let last = labels.last, TopLevelDomains.all.contains(String(last)) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

/// The endings a web address can have: "com", "de", "rs", "app".
enum TopLevelDomains {
    /// The list that ships with Inky, read when the first address is looked
    /// at. It is IANA's, as it is: `make tlds` fetches the current one.
    static let all: Set<String> = {
        guard let url = Bundle.module.url(forResource: "tlds", withExtension: "txt"),
              let list = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("The list of top-level domains is missing")
            return []
        }
        return parse(list)
    }()

    /// One domain to a line, in capitals. A line that starts with "#" says
    /// which version of the list it is.
    static func parse(_ list: String) -> Set<String> {
        Set(
            list.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
    }
}
