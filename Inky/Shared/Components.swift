import AppKit
import InkyCore
import SwiftUI

/// Draws an `Icon`: a Finder icon, a symbol on a tinted tile, or a website's
/// icon on a white one.
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
            tile
                .fill(tint.color)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: name)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .overlay {
                    if outline > 0 { tile.strokeBorder(.white.opacity(outline)) }
                }
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
        }
    }

    private var tile: RoundedRectangle {
        RoundedRectangle(cornerRadius: shape == .circle ? size / 2 : size * 0.26, style: .continuous)
    }
}

final class IconCache {
    static let shared = IconCache()

    /// Set by the app. Without it, websites show their fallback.
    var favicons: FaviconStore?

    private let cache = NSCache<NSString, NSImage>()

    func icon(forFile path: String) -> NSImage {
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
            Text(keys.joined())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone == .onAccent ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 5)
                .frame(minWidth: 22, minHeight: 20)
                .background(
                    tone == .onAccent ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(Theme.subtleFill),
                    in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                )
                .fixedSize()
        }
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

/// A capsule button for the end of the bar. `isProminent` fills it with the accent color.
struct CapsuleButton: View {
    let title: String
    var keys: [String] = []
    var isProminent = false
    let action: () -> Void

    var body: some View {
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
            .background(isProminent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.controlFill), in: Capsule())
            .overlay {
                if !isProminent { Capsule().strokeBorder(Theme.controlStroke) }
            }
            .shadow(color: isProminent ? Theme.accent.opacity(0.35) : Theme.controlShadow, radius: 3, y: 1)
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
