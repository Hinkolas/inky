import AppKit

/// Offers to open a web address that is typed.
@MainActor
public final class BrowserModule: Module {
    public let id = "browser"
    public let info = ModuleInfo(
        title: "Browser",
        summary: "Type a web address to open it in your browser.",
        icon: .symbol("globe", tint: .indigo)
    )
    public var onChange: (@MainActor () -> Void)?

    private let open: @MainActor (URL) -> Bool

    /// `open` hands an address to the browser and says whether that worked.
    /// By default it is the browser the Mac opens links with.
    public init(open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.open = open
    }

    public func instantResults(for query: String) -> [ResultItem] {
        guard let address = WebAddress(query) else { return [] }
        let url = address.url
        let link = url.absoluteString
        return [
            ResultItem(
                id: "browser:open",
                title: "Open in Browser",
                // The address as it will be opened, with the scheme it was
                // typed without.
                subtitle: link,
                // Not the icon of the website: asking for it would tell the
                // icon service every address that is typed, letter by letter.
                icon: info.icon,
                kind: "Link",
                actions: [
                    Action("Open Link", symbol: "arrow.up.forward") { [open] _ in
                        guard open(url) else { throw InkyError("Could not open \(link)") }
                    },
                    .copy(link, title: "Copy Link"),
                ]
            ),
        ]
    }
}
