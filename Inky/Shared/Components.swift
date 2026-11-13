import AppKit
import InkyCore
import SwiftUI

/// Draws an `Icon`: a Finder icon, a symbol on a shaded tile, a website's
/// icon on a white one, or a tile of one color.
struct IconView: View {
    enum Shape {
        case tile, circle
    }

    let icon: Icon
    var size: CGFloat = 24
    var shape: Shape = .tile
    /// How strong a white line is drawn around a tinted tile, to set it off
    /// from a selected row.
    var outline: Double = 0
    /// Whether a website's icon is fetched when it is not there. Off where
    /// the link is still being typed.
    var loadsFavicon = true

    var body: some View {
        switch icon {
        case .file(let path):
            Image(nsImage: IconCache.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        case .symbol(let name, let tint):
            // A little depth, in the spirit of the app icon: light falls from
            // above, catches the top edge and lifts the glyph off the tile.
            let pointSize = size * 0.5
            let nudge = Self.nudges[name] ?? .zero
            tile
                .fill(tint.color)
                .overlay {
                    // Laid over the tint rather than mixed into it: mixing
                    // system colors comes out washed out in the app.
                    tile.fill(LinearGradient(
                        colors: [.white.opacity(0.16), .black.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                }
                .overlay {
                    tile.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                        lineWidth: max(0.5, size / 40)
                    )
                }
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: name)
                        .font(.system(size: pointSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: nudge.width * pointSize, y: nudge.height * pointSize)
                        .shadow(color: .black.opacity(0.18), radius: size * 0.02, y: size * 0.02)
                }
                .overlay {
                    if outline > 0 { tile.strokeBorder(.white.opacity(outline)) }
                }
                .shadow(color: .black.opacity(0.18), radius: size * 0.03, y: size * 0.02)
        case .favicon(let host, let fallback):
            Group {
                if let image = IconCache.shared.favicon(for: host) {
                    // Icons come in any color, and many are see-through: on a
                    // tile of their own they read in light and dark alike.
                    // Two thirds of 24 points is 32 pixels, the size most
                    // websites have.
                    tile
                        .fill(.white)
                        .frame(width: size, height: size)
                        .overlay {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: size * 2 / 3, height: size * 2 / 3)
                        }
                        .overlay { tile.strokeBorder(.black.opacity(0.1)) }
                } else {
                    IconView(icon: fallback, size: size, shape: shape, outline: outline)
                }
            }
            .task(id: host) {
                if loadsFavicon { IconCache.shared.favicons?.load(host) }
            }
        case .picture(let source, let id, let fallback):
            let pictures = IconCache.shared.pictures
            Group {
                if let image = pictures?.image(of: id, from: source) {
                    PictureCircle(image: image, size: size, isSelected: outline > 0)
                } else {
                    IconView(icon: fallback, size: size, shape: shape, outline: outline)
                }
            }
            // Asked for again when the pictures may have changed.
            .task(id: PictureStore.Request(source: source, id: id, generation: pictures?.generation ?? 0)) {
                pictures?.request(id, from: source)
            }
        case .swatch(let red, let green, let blue, let alpha):
            tile
                .fill(Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha))
                .background {
                    // What shows through a color that is see-through.
                    if alpha < 1 { Checkerboard(squares: 4).clipShape(tile) }
                }
                .frame(width: size, height: size)
                // A color may be the one it lies on.
                .overlay { tile.strokeBorder(outline > 0 ? Color.white.opacity(outline) : Color.primary.opacity(0.22)) }
        }
    }

    /// How far to move a symbol, in fractions of its point size, so that it
    /// looks centered on its tile. Symbols center their whole frame, and a
    /// few of them leave room on one side or carry their weight off center.
    private static let nudges: [String: CGSize] = [
        "clipboard.fill": CGSize(width: 0, height: -0.06),
        "doc.text.magnifyingglass": CGSize(width: -0.022, height: 0.033),
        "link.badge.plus": CGSize(width: -0.018, height: 0.01),
        "info": CGSize(width: -0.015, height: 0),
        "restart": CGSize(width: 0.058, height: 0),
    ]

    private var tile: RoundedRectangle {
        RoundedRectangle(cornerRadius: shape == .circle ? size / 2 : size * 0.26, style: .continuous)
    }
}

/// White and gray squares, the way see-through is drawn.
private struct Checkerboard: View {
    let squares: Int

    var body: some View {
        Canvas { context, size in
            let side = size.width / CGFloat(squares)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<squares {
                for column in 0..<squares where (row + column).isMultiple(of: 2) {
                    let square = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
                    context.fill(Path(square), with: .color(Color(white: 0.78)))
                }
            }
        }
    }
}

/// A picture of someone, round. What is see-through in it, as around a
/// Memoji, shows a quiet gray, as it does in Contacts.
struct PictureCircle: View {
    let image: NSImage
    var size: CGFloat = 24
    var isSelected = false

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(white: 0.8), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(isSelected ? Color.white.opacity(0.5) : Color.primary.opacity(0.12))
            }
    }
}

/// The pictures the sources of the search index have of their items, as
/// far as they were shown: a contact's photo, say.
///
/// A picture is asked of its source when a row with it is drawn, and held
/// in memory while there is room. Nothing of it is written to disk. Read
/// while a view draws, this makes the view draw again when the picture
/// arrives.
@Observable
final class PictureStore {
    /// What a view asks for a picture by. It changes, and the view asks
    /// again, when the pictures may have.
    struct Request: Hashable {
        var source: String
        var id: String
        var generation: Int
    }

    private struct Key: Hashable {
        var source: String
        var id: String
    }

    /// Goes up when the items changed, and their pictures may have.
    private(set) var generation = 0
    private var images: [Key: NSImage] = [:]
    /// What was asked for since the items last changed, there or not.
    @ObservationIgnored private var asked: Set<Key> = []
    @ObservationIgnored private let load: (_ source: String, _ id: String) async -> Data?

    /// More than are ever on screen at once.
    private static let limit = 300

    init(load: @escaping (_ source: String, _ id: String) async -> Data?) {
        self.load = load
    }

    func image(of id: String, from source: String) -> NSImage? {
        images[Key(source: source, id: id)]
    }

    /// Asks the source for the picture, once until the items change.
    func request(_ id: String, from source: String) {
        let key = Key(source: source, id: id)
        guard !asked.contains(key) else { return }
        asked.insert(key)
        let generation = generation
        Task {
            let image = await load(source, id).flatMap(NSImage.init(data:))
            // Asked again meanwhile: that answer is the one that counts.
            guard generation == self.generation else { return }
            if image != nil, images.count >= Self.limit {
                images = [:]
                asked = [key]
            }
            images[key] = image
        }
    }

    /// Call when the items of the index changed. The pictures that are
    /// shown stay until they are asked for again, so that nothing blinks.
    func invalidate() {
        asked = []
        generation += 1
    }
}

final class IconCache {
    static let shared = IconCache()

    /// Set by the app. Without it, websites show their fallback.
    var favicons: FaviconStore?
    /// Set by the app. Without it, items show the fallback of their picture.
    var pictures: PictureStore?

    private let cache = NSCache<NSString, NSImage>()

    func icon(forFile path: String) -> NSImage {
        // Finder can keep showing an older icon of a build it has seen before;
        // Inky's own icon comes straight from its bundle.
        if path == Bundle.main.bundlePath, let own = NSApp.applicationIconImage { return own }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    /// The icon of the website at `host`, if one is kept. Read while a view
    /// draws, this makes the view draw again when the icon arrives.
    func favicon(for host: String) -> NSImage? {
        guard let kept = favicons?.icon(for: host) else { return nil }
        // A refreshed icon is a new one.
        let key = "favicon:\(host):\(kept.fetched.timeIntervalSinceReferenceDate)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: kept.url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

extension Icon {
    /// Inky's app icon.
    static var inky: Icon { .file(path: Bundle.main.bundlePath) }
}

extension Tint {
    var color: Color {
        switch self {
        case .gray: .gray
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        }
    }
}

/// A keyboard key or chord, such as ⌘K, drawn as one cap.
struct Keycap: View {
    enum Tone {
        /// On a surface.
        case plain
        /// On the accent color, such as inside a selected row.
        case onAccent
    }

    let keys: [String]
    var tone: Tone = .plain

    init(_ keys: [String], tone: Tone = .plain) {
        self.keys = keys
        self.tone = tone
    }

    var body: some View {
        if !keys.isEmpty {
            let glyphs = keys.map(KeyGlyph.init)
            HStack(spacing: 2) {
                ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                    // Wide enough that a narrow key, such as a comma or an
                    // I, keeps its distance from its neighbors.
                    glyph.frame(minWidth: 9)
                }
            }
            .foregroundStyle(tone == .onAccent ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5.5)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                tone == .onAccent ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(Theme.subtleFill),
                in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
            )
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(glyphs.map(\.spokenName).joined(separator: " "))
        }
    }
}

/// One key of a chord. Modifiers and the keys that have no letter are drawn
/// as SF Symbols: in a line of text those glyphs come in different sizes and
/// sit at different heights.
private struct KeyGlyph: View {
    private enum Content {
        case symbol(String)
        case text(String)
    }

    private let content: Content
    let spokenName: String

    /// `key` is a glyph from `KeyShortcut.symbols` or `KeyCombo.symbols`.
    init(_ key: String) {
        let (content, spokenName): (Content, String) = switch key {
        case "⌘": (.symbol("command"), "Command")
        case "⇧": (.symbol("shift"), "Shift")
        case "⌥": (.symbol("option"), "Option")
        case "⌃": (.symbol("control"), "Control")
        case "↵": (.symbol("return"), "Return")
        case "⌫": (.symbol("delete.left"), "Delete")
        case "⌦": (.symbol("delete.right"), "Forward Delete")
        case "⇥": (.symbol("arrow.right.to.line"), "Tab")
        case "↑": (.symbol("arrow.up"), "Up Arrow")
        case "↓": (.symbol("arrow.down"), "Down Arrow")
        case "←": (.symbol("arrow.left"), "Left Arrow")
        case "→": (.symbol("arrow.right"), "Right Arrow")
        case "␣", "Space": (.text("space"), "Space")
        case "⎋", "esc": (.text("esc"), "Escape")
        default: (.text(key), key)
        }
        self.content = content
        self.spokenName = spokenName
    }

    private static let size: CGFloat = 11
    /// Marks that are thin and small next to a capital.
    private static let smallMarks: Set<Character> = [",", ".", ";", ":", "'", "`", "-"]
    /// Those of them that sit on the baseline, far below the middle of a cap.
    private static let lowMarks: Set<Character> = [",", ".", ";"]

    var body: some View {
        switch content {
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: Self.size * 0.92, weight: .semibold))
        case let .text(text):
            if text.count == 1, let mark = text.first, Self.smallMarks.contains(mark) {
                Text(text)
                    .font(.system(size: Self.size * 1.25, weight: .bold))
                    .baselineOffset(Self.lowMarks.contains(mark) ? Self.size * 0.3 : 0)
            } else {
                // A word, such as esc, is a little smaller than a letter.
                Text(text)
                    .font(.system(size: text.count > 1 ? Self.size * 0.95 : Self.size, weight: .semibold))
            }
        }
    }
}

/// A box that is ticked or not. It is only drawn: what it is in takes the click.
struct Checkbox: View {
    let isOn: Bool
    /// On the accent color, such as inside a selected row.
    var isOnAccent = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack {
            if isOn {
                shape.fill(isOnAccent ? Theme.onAccent : Theme.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(isOnAccent ? Theme.accent : Theme.onAccent)
            } else {
                shape.strokeBorder(isOnAccent ? AnyShapeStyle(Theme.onAccent.opacity(0.75)) : AnyShapeStyle(.tertiary), lineWidth: 1.5)
            }
        }
        .frame(width: 17, height: 17)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOn ? "Selected" : "Not selected")
    }
}

/// The keys that matter right now, below the card on a small surface of
/// their own so they stay readable over any wallpaper.
struct KeyHintBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) { content }
            // As wide as what it says, whatever room it is given while the
            // launcher around it changes size.
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 32)
            .glassSurface(cornerRadius: nil)
    }
}

/// Keys and what they do. One cap per chord: keys pressed together share a
/// cap, keys that are alternatives each get their own.
struct KeyHint<Title: View>: View {
    let chords: [[String]]
    let title: Title

    init(_ chords: [String]..., @ViewBuilder title: () -> Title) {
        self.chords = chords
        self.title = title()
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(chords, id: \.self) { Keycap($0) }
            }
            title
        }
    }
}

extension KeyHint where Title == KeyHintLabel {
    init(_ chords: [String]..., title: String) {
        self.chords = chords
        self.title = KeyHintLabel(title)
    }
}

/// What a key does: a word that is never broken or cut short.
struct KeyHintLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Dims its label while pressed, and lets it give a little. For buttons that
/// draw their own background.
struct PressableButtonStyle: ButtonStyle {
    /// How small the label gets while pressed. Pass 1 for a row that spans
    /// its panel, which would pull away from the edges.
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        PressableLabel(configuration: configuration, pressedScale: pressedScale)
    }
}

private struct PressableLabel: View {
    let configuration: ButtonStyleConfiguration
    let pressedScale: CGFloat
    @Environment(\.motion) private var motion

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && motion.level == .full ? pressedScale : 1)
            .animation(motion.press, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// A round button that sits on a surface, such as the one for more actions.
struct CircleButton: View {
    let symbol: String
    var size: CGFloat = 32
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: size, height: size)
                .background(Theme.controlFill, in: Circle())
                .overlay { Circle().strokeBorder(Theme.controlStroke) }
                .shadow(color: Theme.controlShadow, radius: 3, y: 1)
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }
}

/// A capsule button for the end of the bar. `isProminent` fills it with the
/// accent color, or with red if what it does is `isDestructive`.
struct CapsuleButton: View {
    let title: String
    var keys: [String] = []
    var isProminent = false
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        let fill = isDestructive ? Theme.destructiveFill : Theme.accent
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(isProminent ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
                Keycap(keys, tone: isProminent ? .onAccent : .plain)
            }
            .padding(.leading, 16)
            .padding(.trailing, keys.isEmpty ? 16 : 9)
            .frame(height: LauncherMetrics.barControlSize)
            .background(isProminent ? AnyShapeStyle(fill) : AnyShapeStyle(Theme.controlFill), in: Capsule())
            .overlay {
                if !isProminent { Capsule().strokeBorder(Theme.controlStroke) }
            }
            .shadow(color: isProminent ? fill.opacity(0.35) : Theme.controlShadow, radius: 3, y: 1)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// A small capsule that inserts or picks something.
struct Chip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.subtleFill, in: Capsule())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Lays views out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, rows.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}
