import AppKit
import InkyCore
import SwiftUI

/// Picks a color from anywhere on the screen with the loupe of macOS, and
/// copies it the way the Color module says. A card beside the pointer says
/// what was copied.
///
/// The loupe is the system's own: it needs no permission to see the screen,
/// and Esc puts it away without a color.
@MainActor
enum ColorPicker {
    /// The loupe on screen, kept until it is done. Nil while there is none.
    private static var sampler: NSColorSampler?

    static func pick(with module: ColorModule) {
        // Running the command again while the loupe is out leaves it there.
        guard sampler == nil else { return }
        let sampler = NSColorSampler()
        Self.sampler = sampler
        sampler.show { color in
            Task { @MainActor in
                Self.sampler = nil
                guard let color, let copied = module.copy(picked: color) else { return }
                showCopied(copied.color, text: copied.text, format: module.pickFormat)
            }
        }
    }

    /// Says beside the pointer that `text` was copied, with a swatch of `color`.
    static func showCopied(_ color: ColorValue, text: String, format: ColorValue.Format) {
        let shown = color.displayed
        let swatch = Color(.sRGB, red: shown.red, green: shown.green, blue: shown.blue)
        ScreenToast.show(CopiedColorCard(swatch: swatch, text: text, format: format))
    }
}

/// A swatch of the color, what was copied, and the way it was written.
///
/// Where things may travel, the swatch lands in the card with a bounce as
/// the card grows out of the pointer, and the words follow.
private struct CopiedColorCard: View {
    let swatch: Color
    let text: String
    let format: ColorValue.Format

    @Environment(\.motion) private var motion
    @State private var hasLanded = false

    var body: some View {
        let landed = hasLanded || motion.level != .full
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(swatch)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                )
                .frame(width: 36, height: 36)
                .scaleEffect(landed ? 1 : 0.3)
                .animation(motion.pop, value: landed)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text("Copied as \(format.title)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .opacity(landed ? 1 : 0)
            .offset(x: landed ? 0 : -8)
            .animation(motion.reveal, value: landed)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .frame(height: 56)
        .fixedSize()
        .glassSurface(cornerRadius: 16)
        .onAppear { hasLanded = true }
    }
}
