import AppKit
import SwiftUI

/// The launcher's measurements. Everything floats on a transparent canvas: a
/// bar on top, and below it, unconnected, whatever the bar is showing.
enum LauncherMetrics {
    static let barHeight: CGFloat = 48
    /// Between the bar and the card below it, and between the back button and the bar.
    static let gap: CGFloat = 10
    static let searchWidth: CGFloat = 680
    static let cardRadius: CGFloat = 26
    /// Sidebars and side panels sit inside a card, this far from its edge.
    static let panelInset: CGFloat = 10
    static let panelRadius: CGFloat = cardRadius - panelInset
    static let rowHeight: CGFloat = 40
    static let rowRadius: CGFloat = 10
    static let sectionHeaderHeight: CGFloat = 30
    static let listMaxHeight: CGFloat = 420

    /// How much lower the search bar sits than a command's header. A command
    /// needs the room below; the search bar looks better near eye level.
    static let searchDrop: CGFloat = 68
    /// Room around the content for shadows.
    static let margin = NSEdgeInsets(top: 40, left: 60, bottom: 94, right: 60)
    static let maxContentSize = NSSize(width: 940, height: 626)
    static let canvas = NSSize(
        width: maxContentSize.width + margin.left + margin.right,
        height: maxContentSize.height + margin.top + margin.bottom
    )
}

/// The launcher's colors. Each has a light and a dark value and follows the
/// appearance of the window it is drawn in.
enum Theme {
    static let accent = Color(light: .hex(0x2563EB), dark: .hex(0x2F6BEB))
    static let onAccent = Color.white
    /// The accent as a text color, readable on a dark surface too.
    static let accentText = Color(light: .hex(0x2563EB), dark: .hex(0x8DB2FF))
    static let destructive = Color(light: .hex(0xB42318), dark: .hex(0xFF7B72))

    /// Laid over the blur of a floating surface.
    static let glassTint = Color(light: .white.alpha(0.62), dark: .hex(0x14172A, alpha: 0.46))
    static let glassStroke = Color(light: .white.alpha(0.8), dark: .white.alpha(0.14))
    /// Under a floating surface, where only its shadow shows.
    static let glassBase = Color(light: .hex(0xEEF1FA), dark: .hex(0x14172A))
    static let shadow = Color(light: .hex(0x1F2A55, alpha: 0.2), dark: .black.alpha(0.5))

    /// Sidebars, side panels and grouped form rows.
    static let panelFill = Color(light: .white.alpha(0.5), dark: .white.alpha(0.05))
    static let panelStroke = Color(light: .white.alpha(0.7), dark: .white.alpha(0.07))

    /// Text areas and previews.
    static let fieldFill = Color(light: .white.alpha(0.88), dark: .black.alpha(0.24))
    static let fieldStroke = Color(light: .black.alpha(0.08), dark: .white.alpha(0.09))

    /// Buttons that sit on a surface.
    static let controlFill = Color(light: .white, dark: .white.alpha(0.11))
    static let controlStroke = Color(light: .black.alpha(0.06), dark: .white.alpha(0.1))
    static let controlShadow = Color(light: .hex(0x1F2A55, alpha: 0.14), dark: .clear)

    /// Chips, keycaps and the selected row of a sidebar.
    static let subtleFill = Color(light: .black.alpha(0.065), dark: .white.alpha(0.1))
    static let separator = Color(light: .black.alpha(0.09), dark: .white.alpha(0.1))
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    static func hex(_ value: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    func alpha(_ alpha: CGFloat) -> NSColor {
        withAlphaComponent(alpha)
    }
}

// MARK: - Glass

/// The outline of a floating surface: a capsule, or a rounded rectangle.
nonisolated struct SurfaceShape: InsettableShape {
    /// Nil draws a capsule.
    var cornerRadius: CGFloat?
    private var inset: CGFloat = 0

    init(cornerRadius: CGFloat?) {
        self.cornerRadius = cornerRadius
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        guard let cornerRadius else { return Capsule().path(in: rect) }
        return RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous).path(in: rect)
    }

    func inset(by amount: CGFloat) -> SurfaceShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

extension View {
    /// Puts the view on a translucent surface that floats over whatever is
    /// behind the window. Pass nil for a capsule.
    func glassSurface(cornerRadius: CGFloat?) -> some View {
        let shape = SurfaceShape(cornerRadius: cornerRadius)
        return background {
            ZStack {
                // The blur shows what is behind the window, so nothing drawn
                // under it is seen. This shape is only there to cast shadows.
                shape
                    .fill(Theme.glassBase)
                    .shadow(color: Theme.shadow, radius: 26, y: 14)
                    .shadow(color: Theme.shadow.opacity(0.35), radius: 3, y: 1)
                BehindWindowBlur(cornerRadius: cornerRadius)
                shape.fill(Theme.glassTint)
                shape.strokeBorder(Theme.glassStroke, lineWidth: 1)
            }
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    var cornerRadius: CGFloat?

    func makeNSView(context: Context) -> MaskedEffectView {
        let view = MaskedEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // The panel is not always the key window, and must not gray out.
        view.state = .active
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: MaskedEffectView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}

/// A visual effect view cut to a rounded shape. Clipping from SwiftUI does not
/// reach a blur that is composited behind the window; a mask image does.
private final class MaskedEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat? {
        didSet {
            if cornerRadius != oldValue { needsLayout = true }
        }
    }

    private var maskKey: CGFloat = 0

    override func layout() {
        super.layout()
        // Negative keys are capsules, which depend on the height.
        let key = cornerRadius ?? -bounds.height / 2
        guard key != maskKey, key != 0 else { return }
        maskKey = key
        maskImage = Self.mask(radius: abs(key), continuous: key > 0)
    }

    /// A small image of the shape that stretches from its middle.
    private static func mask(radius: CGFloat, continuous: Bool) -> NSImage {
        // A continuous corner starts bending well before its radius.
        let cap = ceil(continuous ? radius * 1.6 : radius)
        let side = cap * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = continuous
                ? RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
                : CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path)
            context.setFillColor(.black)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }
}
