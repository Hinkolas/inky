import AppKit
import InkyCore

/// Picks a color from anywhere on the screen with the loupe of macOS, and
/// copies it the way the Color module says.
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
                guard let color else { return }
                module.copy(picked: color)
            }
        }
    }
}
