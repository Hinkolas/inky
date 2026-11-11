import Foundation

/// Shows a color that is typed, and writes it the other ways there are.
///
/// "#ff6363" answers with the way of writing that is copied most from that
/// kind of color; the others are a ⌘K away. "#ff6363 in hsl" asks for one.
@MainActor
public final class ColorModule: Module {
    public let id = "color"
    public let info = ModuleInfo(
        title: "Color",
        summary: "Type a color the way a stylesheet writes it to see it and copy it written another way.",
        icon: .symbol("paintpalette.fill", tint: .pink)
    )
    public var onChange: (@MainActor () -> Void)?

    private let usage: UsageStore?

    /// With `usage`, what is copied is remembered, and the way of writing
    /// that is copied most comes first.
    public init(usage: UsageStore? = nil) {
        self.usage = usage
    }

    public func instantResults(for query: String) -> [ResultItem] {
        guard let request = ColorRequest(query) else { return [] }
        let color = request.color
        let shown = color.displayed
        var formats = formats(for: color.notation)
        if let asked = request.format {
            formats.removeAll { $0 == asked }
            formats.insert(asked, at: 0)
        }
        return [
            ResultItem(
                id: "color:result",
                title: color.text(as: formats[0]),
                // Only a color was typed: two more ways, to save a look at the rest.
                subtitle: request.format == nil ? formats[1...2].map { color.text(as: $0) }.joined(separator: " · ") : nil,
                icon: .swatch(red: shown.red, green: shown.green, blue: shown.blue, alpha: shown.alpha),
                kind: "Color",
                actions: formats.map { format in
                    let text = color.text(as: format)
                    let key = Self.key(from: color.notation, to: format)
                    return Action("Copy as \(format.title)", symbol: "doc.on.doc") { [usage] _ in
                        Pasteboard.copy(text)
                        usage?.record(key, query: "")
                    }
                }
            ),
        ]
    }

    /// Every way of writing, the one copied most from `notation` first.
    /// Until something was copied, the way it was typed in comes last: that
    /// is the one already there.
    func formats(for notation: ColorValue.Notation) -> [ColorValue.Format] {
        let formats = ColorValue.Format.allCases.filter { $0.notation != notation }
            + ColorValue.Format.allCases.filter { $0.notation == notation }
        guard let usage else { return formats }
        let scores = formats.map { usage.frecency(Self.key(from: notation, to: $0)) }
        // Where two are used as much, they stay in the order they were in.
        return formats.indices
            .sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
            .map { formats[$0] }
    }

    /// What a copy is remembered under: "color:hex>rgb".
    static func key(from notation: ColorValue.Notation, to format: ColorValue.Format) -> String {
        "color:\(notation.rawValue)>\(format.rawValue)"
    }
}
