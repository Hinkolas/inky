import AppKit
import Testing
@testable import InkyCore

/// Colors picked from the screen, which AppKit hands over.
@Suite struct ColorPickingTests {
    private static let ninetyNine: CGFloat = 99.0 / 255

    private func parts(_ color: ColorValue) -> [Int] {
        [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
    }

    @Test func aPickedColorIsReadAsSRGB() throws {
        let picked = try #require(ColorValue(nsColor: NSColor(srgbRed: 1, green: Self.ninetyNine, blue: Self.ninetyNine, alpha: 1)))
        #expect(parts(picked) == [255, 99, 99])
        #expect(picked.alpha == 1)
        #expect(picked.text(as: .hex) == "#FF6363")

        let gray = try #require(ColorValue(nsColor: NSColor(white: 0.5, alpha: 1)))
        #expect(gray.isInGamut)
        #expect(Set(parts(gray)).count == 1)
    }

    @Test func aColorOfAWiderScreenKeepsWhatSRGBCannotShow() throws {
        // The reddest red of a Display P3 screen lies beyond sRGB's.
        let picked = try #require(ColorValue(nsColor: NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)))
        #expect(!picked.isInGamut)
        #expect(picked.red > 1)
        // Hex says the nearest color it can, the wider ways the color itself.
        #expect(picked.text(as: .hex) == picked.displayed.text(as: .hex))
        let oklch = try #require(ColorValue(picked.text(as: .oklch)))
        #expect(abs(oklch.red - picked.red) < 0.01)
    }

    @Test func aPatternIsNoColor() {
        #expect(ColorValue(nsColor: NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))) == nil)
    }

    @MainActor
    @Test func pickColorIsACommand() async throws {
        let module = ColorModule()
        var picks = 0
        module.onPick = { picks += 1 }
        let command = try #require(await module.candidates().first)
        #expect(command.id == ColorModule.pickID)
        #expect(command.title == "Pick Color")
        #expect(command.kind == "Command")
        try await command.actions.first?.perform(ActionContext())
        #expect(picks == 1)
    }
}
