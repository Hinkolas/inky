import AppKit
import Observation

/// A named shortcut to a URL, folder or deeplink, with optional placeholders.
public struct Quicklink: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var link: String
    /// Bundle identifier of the app to open the link with. Nil uses the default app.
    public var openWith: String?

    public init(id: UUID = UUID(), name: String, link: String, openWith: String? = nil) {
        self.id = id
        self.name = name
        self.link = link
        self.openWith = openWith
    }

    public var template: LinkTemplate { LinkTemplate(link) }

    public enum Kind: Sendable, Hashable, CaseIterable {
        case website, file, appLink
    }

    /// What the link points at, judged by how it starts.
    public var kind: Kind {
        let link = link.trimmingCharacters(in: .whitespaces)
        if link.hasPrefix("/") || link.hasPrefix("~") { return .file }
        guard let scheme = link.firstMatch(of: /^([A-Za-z][A-Za-z0-9+.-]*):/)?.1 else { return .website }
        return ["http", "https"].contains(scheme.lowercased()) ? .website : .appLink
    }
}

/// The user's quicklinks, kept as a JSON file that is easy to read, edit and sync.
@MainActor
@Observable
public final class QuicklinkStore {
    public private(set) var quicklinks: [Quicklink] = []

    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let fileURL: URL?

    /// Pass nil to keep the quicklinks in memory only.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL else { return }
        if let data = try? Data(contentsOf: fileURL) {
            quicklinks = (try? JSONDecoder().decode([Quicklink].self, from: data)) ?? []
        } else {
            quicklinks = Self.starters
            write()
        }
    }

    /// Adds the quicklink, or replaces the one with the same id.
    public func save(_ quicklink: Quicklink) {
        if let index = quicklinks.firstIndex(where: { $0.id == quicklink.id }) {
            quicklinks[index] = quicklink
        } else {
            quicklinks.append(quicklink)
        }
        didChange()
    }

    public func delete(_ id: UUID) {
        quicklinks.removeAll { $0.id == id }
        didChange()
    }

    /// Written on first launch so the feature is discoverable.
    private static let starters = [
        Quicklink(name: "Search DuckDuckGo", link: "https://duckduckgo.com/?q={argument name=\"Query\"}"),
        Quicklink(name: "Search GitHub", link: "https://github.com/search?q={argument name=\"Query\"}"),
        Quicklink(name: "Search Wikipedia", link: "https://en.wikipedia.org/w/index.php?search={argument name=\"Query\"}"),
        Quicklink(name: "Downloads", link: "~/Downloads"),
    ]

    private func didChange() {
        write()
        onChange?()
    }

    private func write() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(quicklinks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

public enum QuicklinkOpener {
    /// The link with every placeholder filled in from the current context.
    @MainActor
    public static func resolve(_ quicklink: Quicklink, context: ActionContext) -> String {
        let template = quicklink.template
        return template.resolve(LinkTemplate.Values(
            arguments: context.arguments,
            clipboard: template.uses(.clipboard) ? Pasteboard.text ?? "" : "",
            selection: template.uses(.selection) ? SelectedText.read(from: context.frontmostPID) ?? "" : ""
        ))
    }

    public static func url(from link: String) throws -> URL {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { throw InkyError("The quicklink has no link") }

        if link.hasPrefix("/") || link.hasPrefix("~") {
            return URL(fileURLWithPath: (link as NSString).expandingTildeInPath)
        }
        // "example.com/page" is meant as a web address.
        let hasScheme = link.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.-]*:.*/) != nil
        guard let url = URL(string: hasScheme ? link : "https://" + link) else {
            throw InkyError("“\(link)” is not a valid link")
        }
        return url
    }

    @MainActor
    public static func open(_ quicklink: Quicklink, context: ActionContext) throws {
        let url = try url(from: resolve(quicklink, context: context))

        if let bundleID = quicklink.openWith {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw InkyError("The app chosen for “\(quicklink.name)” is not installed")
            }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else if url.isFileURL {
            try Opener.open(path: url.path)
        } else if !NSWorkspace.shared.open(url) {
            throw InkyError("Could not open \(url.absoluteString)")
        }
    }
}
