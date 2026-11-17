import Foundation
import Testing
@testable import InkyCore

@Suite struct ColorTests {
    private func parts(_ color: ColorValue) -> [Int] {
        [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
    }

    // MARK: - Reading

    private static let readings: [(input: String, parts: [Int], alpha: Double)] = [
        ("#ff6363", [255, 99, 99], 1.0),
        ("#FF6363", [255, 99, 99], 1.0),
        ("#f63", [255, 102, 51], 1.0),
        ("#f638", [255, 102, 51], 136.0 / 255),
        ("#ff636380", [255, 99, 99], 128.0 / 255),
        ("  #ff6363;  ", [255, 99, 99], 1.0),
        ("rgb(255, 99, 99)", [255, 99, 99], 1.0),
        ("rgb(255,99,99)", [255, 99, 99], 1.0),
        ("RGB(255 99 99)", [255, 99, 99], 1.0),
        ("rgba(255, 99, 99, 0.5)", [255, 99, 99], 0.5),
        ("rgb(255 99 99 / 50%)", [255, 99, 99], 0.5),
        ("rgb(100% 0% 50%)", [255, 0, 128], 1.0),
        ("rgb(300 -20 99)", [255, 0, 99], 1.0),
        ("hsl(0 100% 69.4%)", [255, 99, 99], 1.0),
        ("hsl(120, 100%, 25%)", [0, 128, 0], 1.0),
        ("hsla(240, 100%, 50%, 0.25)", [0, 0, 255], 0.25),
        ("hsl(0.5turn 100% 50%)", [0, 255, 255], 1.0),
        ("hsl(-120deg 100% 50%)", [0, 0, 255], 1.0),
        ("hsl(none 0% 50%)", [128, 128, 128], 1.0),
        ("hwb(0 38.8% 0%)", [255, 99, 99], 1.0),
        ("hwb(120 0% 50%)", [0, 128, 0], 1.0),
        ("hwb(0 80% 80%)", [128, 128, 128], 1.0),
        ("lab(54.29 80.8 69.89)", [255, 0, 0], 1.0),
        ("lab(46.28% -47.55 48.59)", [0, 128, 0], 1.0),
        ("lch(54.29 106.84 40.86)", [255, 0, 0], 1.0),
        ("oklab(0.62796 0.22486 0.12585)", [255, 0, 0], 1.0),
        ("oklch(0.62796 0.25768 29.234)", [255, 0, 0], 1.0),
        ("oklch(62.796% 0.25768 29.234deg / 0.5)", [255, 0, 0], 0.5),
        ("oklch(1 0 0)", [255, 255, 255], 1.0),
        ("lab(0 0 0)", [0, 0, 0], 1.0),
    ]

    @Test(arguments: readings.indices)
    func readsAColor(index: Int) throws {
        let (input, expected, alpha) = Self.readings[index]
        let color = try #require(ColorValue(input), "\(input)")
        #expect(parts(color) == expected, "\(input)")
        #expect(abs(color.alpha - alpha) < 1e-9, "\(input)")
    }

    @Test(arguments: [
        "", "#", "#ff", "#ff636", "#ff63631", "#ff6363801", "#gg0000", "ff6363", "# ff6363", "#ff6363 x", "#ff6363;;",
        "red", "transparent", "rgb", "rgb(", "rgb()", "rgb(255, 99)", "rgb(255, 99, 99", "rgb(255, 99, 99))",
        "rgb(255 99, 99)", "rgb(255, 99 99)", "rgb(255, 99, 99 / 0.5)", "rgb(255 99 99, 0.5)", "rgb(255 99 99 0.5)",
        "rgb(a b c)", "rgb(255deg 99 99)", "rgb(1e 2 3)", "hsl(50% 50% 50%)", "hsl(0 100% 50deg)", "hsl(0 100px 50%)",
        "hwb(0, 20%, 20%)", "lab(50, 20, 20)", "oklch(0.5 0.1)", "oklch(0.5 0.1 20 30)", "color(display-p3 1 0 0)",
        "rgb(255 99 99) + 1", "1 + #ff6363", "rgb(1e999 0 0)", "lab(nan 0 0)", "#１２３",
    ])
    func whatIsNotAColorIsNone(input: String) {
        #expect(ColorValue(input) == nil)
    }

    @Test func remembersHowItWasWritten() {
        #expect(ColorValue("#fff")?.notation == .hex)
        #expect(ColorValue("rgba(0, 0, 0, 1)")?.notation == .rgb)
        #expect(ColorValue("hsla(0, 0%, 0%, 1)")?.notation == .hsl)
        #expect(ColorValue("hwb(0 0% 0%)")?.notation == .hwb)
        #expect(ColorValue("lab(0 0 0)")?.notation == .lab)
        #expect(ColorValue("lch(0 0 0)")?.notation == .lch)
        #expect(ColorValue("oklab(0 0 0)")?.notation == .oklab)
        #expect(ColorValue("oklch(0 0 0)")?.notation == .oklch)
    }

    // MARK: - Writing

    private static let writings: [(format: ColorValue.Format, text: String)] = [
        (.hex, "#FF6363"),
        (.rgb, "rgb(255, 99, 99)"),
        (.hsl, "hsl(0, 100%, 69.4%)"),
        (.hwb, "hwb(0 39% 0%)"),
        (.oklch, "oklch(0.7 0.191 23.4)"),
        (.swiftUI, "Color(red: 1, green: 0.388, blue: 0.388)"),
        (.nsColor, "NSColor(srgbRed: 1, green: 0.388, blue: 0.388, alpha: 1)"),
        (.uiColor, "UIColor(red: 1, green: 0.388, blue: 0.388, alpha: 1)"),
    ]

    @Test func writesAColor() throws {
        let color = try #require(ColorValue("#ff6363"))
        for (format, expected) in Self.writings {
            #expect(color.text(as: format) == expected)
        }
    }

    @Test func writesWhatItKnowsOfRed() throws {
        let red = try #require(ColorValue("#f00"))
        #expect(red.text(as: .lab) == "lab(54.3 80.8 69.9)")
        #expect(red.text(as: .lch) == "lch(54.29 106.84 40.86)")
        #expect(red.text(as: .oklab) == "oklab(0.628 0.2249 0.1258)")
        #expect(red.text(as: .oklch) == "oklch(0.628 0.2577 29.23)")
    }

    @Test func saysHowSeeThroughItIs() throws {
        let color = try #require(ColorValue("rgb(255 99 99 / 50%)"))
        #expect(color.text(as: .hex) == "#FF636380")
        #expect(color.text(as: .rgb) == "rgba(255, 99, 99, 0.5)")
        #expect(color.text(as: .hsl) == "hsla(0, 100%, 69.4%, 0.5)")
        #expect(color.text(as: .oklch) == "oklch(0.7 0.191 23.4 / 0.5)")
        #expect(color.text(as: .swiftUI) == "Color(red: 1, green: 0.388, blue: 0.388, opacity: 0.5)")
    }

    @Test func aGrayHasNoHue() throws {
        for input in ["#808080", "#fff", "#000", "rgb(17, 17, 17)"] {
            let gray = try #require(ColorValue(input))
            #expect(gray.text(as: .hsl).hasPrefix("hsl(0, 0%, "))
            #expect(gray.text(as: .oklch).hasSuffix(" 0 0)"))
            #expect(gray.text(as: .lch).hasSuffix(" 0 0)"))
        }
        #expect(ColorValue("#fff")?.text(as: .oklch) == "oklch(1 0 0)")
        #expect(ColorValue("#fff")?.text(as: .lab) == "lab(100 0 0)")
        #expect(ColorValue("#000")?.text(as: .oklab) == "oklab(0 0 0)")
    }

    /// Every format a stylesheet reads is read back as the color it was
    /// written from.
    @Test func whatIsWrittenIsReadBackTheSame() throws {
        var generator = SystemRandomNumberGenerator()
        var inputs = ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#010101", "#FEFEFE", "#7F8081"]
        for _ in 0..<300 {
            inputs.append("#" + (0..<6).map { _ in String(Int.random(in: 0..<16, using: &generator), radix: 16) }.joined())
        }
        for input in inputs {
            let color = try #require(ColorValue(input))
            for format in ColorValue.Format.allCases where format.notation != nil {
                let text = color.text(as: format)
                let back = try #require(ColorValue(text), "\(text) of \(input)")
                #expect(parts(back) == parts(color), "\(input) as \(text)")
                #expect(back.notation == format.notation)
            }
        }
    }

    // MARK: - Colors a screen cannot show

    @Test func aColorOutsideOfWhatIsShownKeepsItsHue() throws {
        // Stronger than any green sRGB has.
        let color = try #require(ColorValue("oklch(0.8 0.4 145)"))
        #expect(!color.isInGamut)
        let shown = color.displayed
        #expect(shown.isInGamut)
        let (lightness, chroma, hue) = shown.oklch
        #expect(abs(lightness - 0.8) < 0.01)
        #expect(abs(hue - 145) < 1)
        #expect(chroma < 0.4)
        #expect(chroma > 0.2)
        // What it was is still known.
        #expect(color.text(as: .oklch) == "oklch(0.8 0.4 145)")
        // The others say what is shown, and no more exactly than they have to.
        #expect(color.text(as: .hex) == "#00E540")
        #expect(color.text(as: .hsl) == "hsl(136.93, 100%, 44.81%)")
    }

    @Test func howSeeThroughIsReadBackTheSame() throws {
        for step in 0...255 {
            let color = ColorValue(red: 1, green: 0.5, blue: 0, alpha: Double(step) / 255)
            for format in ColorValue.Format.allCases where format.notation != nil {
                let back = try #require(ColorValue(color.text(as: format)))
                #expect(Int((back.alpha * 255).rounded()) == step, "\(color.text(as: format))")
            }
        }
        #expect(ColorValue("#ff636380")?.text(as: .rgb) == "rgba(255, 99, 99, 0.5)")
        #expect(ColorValue("#ff636381")?.text(as: .rgb) == "rgba(255, 99, 99, 0.506)")
    }

    @Test func lightnessBeyondWhiteAndBlackEndsThere() throws {
        #expect(ColorValue("oklch(1 0.3 20)")?.text(as: .hex) == "#FFFFFF")
        #expect(ColorValue("oklch(0 0.3 20)")?.text(as: .hex) == "#000000")
        #expect(ColorValue("lab(150 0 0)")?.text(as: .hex) == "#FFFFFF")
    }

    @Test func anythingTypedEndsWithAColorOrNone() {
        var generator = SystemRandomNumberGenerator()
        let pieces = [
            "#", "f", "0", "9", "a", "rgb", "rgba", "hsl", "hwb", "lab", "lch", "oklab", "oklch", "(", ")", ",", "/", " ",
            "%", "deg", "turn", "rad", "none", ".", "-", "+", "e", "1", "255", "0.5", "1e3", "é", "🎨", ";",
        ]
        for _ in 0..<5000 {
            let input = (0..<Int.random(in: 0..<14, using: &generator))
                .map { _ in pieces.randomElement(using: &generator)! }
                .joined()
            _ = ColorRequest(input + [" in rgb", " to", " -> hsl", ""].randomElement(using: &generator)!)
            if let color = ColorValue(input) {
                let parts = [color.red, color.green, color.blue, color.alpha]
                #expect(parts.allSatisfy { $0.isFinite }, "\(input)")
                for format in ColorValue.Format.allCases {
                    #expect(!color.text(as: format).isEmpty)
                }
            }
        }
        #expect(ColorValue(String(repeating: "(", count: 5000)) == nil)
        #expect(ColorValue("#" + String(repeating: "f", count: 5000)) == nil)
    }

    // MARK: - Asking for a way of writing

    @Test func aWayOfWritingCanBeAskedFor() throws {
        let cases: [(String, ColorValue.Format)] = [
            ("#fa32fa in rgb", .rgb), ("rgb(255,0,0) in hsl", .hsl), ("#fff to oklch", .oklch), ("#fff as HEX", .hex),
            ("#fff → lab", .lab), ("#fff -> lch", .lch), ("#fff => hwb", .hwb), ("hsl(0 100% 50%)in rgba", .rgb),
            ("#fff in swiftui", .swiftUI), ("#fff in swift", .swiftUI), ("#fff in NSColor", .nsColor),
            ("#fff in uicolor", .uiColor), ("#fff in oklab", .oklab), ("  #fff   in   hsla ;", .hsl),
        ]
        for (input, format) in cases {
            let request = try #require(ColorRequest(input), "\(input)")
            #expect(request.format == format, "\(input)")
        }
        #expect(ColorRequest("#fa32fa in rgb")?.color == ColorValue("#fa32fa"))
        #expect(try #require(ColorRequest("#ff6363")).format == nil)
        #expect(ColorRequest("hsl(120 none 50%)")?.format == nil)
    }

    @Test(arguments: [
        "#fff in", "#fff rgb", "#fff in red", "#fff in rgb hsl", "#fff in rgb in hsl", "#fff inrgb", "#fff - rgb",
        "#fff > rgb", "#fff in 5", "#fff in rgb(", "in rgb", "#fff in cm", "fff in rgb", "255 in hex",
    ])
    func whatAsksForNoWayOfWritingIsNone(input: String) {
        #expect(ColorRequest(input) == nil)
    }

    // MARK: - The module

    @MainActor
    @Test func aColorIsOneRowWithEveryWayToWriteIt() throws {
        let module = ColorModule()
        let rows = module.instantResults(for: "#ff6363")
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.title == "rgb(255, 99, 99)")
        #expect(row.subtitle == "hsl(0, 100%, 69.4%) · oklch(0.7 0.191 23.4)")
        #expect(row.icon == .swatch(red: 1, green: 99.0 / 255, blue: 99.0 / 255, alpha: 1))
        // Return copies what the row says, every other way is an action, and
        // the way it was typed is the last of them.
        #expect(row.actions.first?.title == "Copy as RGB")
        #expect(row.actions.last?.title == "Copy as Hex")
        #expect(row.actions.count == ColorValue.Format.allCases.count)
        #expect(Set(row.actions.map(\.id)).count == row.actions.count)

        #expect(module.instantResults(for: "oklch(0.7 0.19 23)").first?.actions.first?.title == "Copy as Hex")
        #expect(module.instantResults(for: "lab(50 20 20)").first?.actions.first?.title == "Copy as Hex")
    }

    @MainActor
    @Test func theWayAskedForIsTheAnswer() throws {
        let module = ColorModule()
        let row = try #require(module.instantResults(for: "#fa32fa in rgb").first)
        #expect(row.title == "rgb(250, 50, 250)")
        #expect(row.subtitle == nil)
        #expect(row.actions.first?.title == "Copy as RGB")
        #expect(row.actions.count == ColorValue.Format.allCases.count)

        #expect(module.instantResults(for: "rgb(255,0,0) in hsl").first?.title == "hsl(0, 100%, 50%)")
        // The way it is written already can be asked for too.
        #expect(module.instantResults(for: "#f63 in hex").first?.title == "#FF6633")
        #expect(module.instantResults(for: "#fff in").isEmpty)
    }

    @MainActor
    @Test func theWayCopiedMostComesFirst() throws {
        let usage = UsageStore(fileURL: nil)
        let module = ColorModule(usage: usage)
        #expect(module.formats(for: .hex).first == .rgb)
        #expect(module.formats(for: .hex).last == .hex)

        usage.record(ColorModule.key(from: .hex, to: .oklch), query: "")
        #expect(module.formats(for: .hex).prefix(2) == [.oklch, .rgb])
        #expect(module.instantResults(for: "#ff6363").first?.title == "oklch(0.7 0.191 23.4)")
        // What is copied from one kind of color says nothing about another.
        #expect(module.formats(for: .rgb).first == .hex)

        usage.record(ColorModule.key(from: .hex, to: .hsl), query: "")
        usage.record(ColorModule.key(from: .hex, to: .hsl), query: "")
        #expect(module.formats(for: .hex).prefix(3) == [.hsl, .oklch, .rgb])
        #expect(Set(module.formats(for: .hex)).count == ColorValue.Format.allCases.count)
        // Asking for one still gives that one.
        #expect(module.instantResults(for: "#ff6363 in rgb").first?.title == "rgb(255, 99, 99)")
    }

    @MainActor
    @Test func whatIsNotAColorHasNoRow() {
        let module = ColorModule()
        for query in ["red", "ff6363", "#", "#12", "rgb", "safari", "255, 99, 99", "#ff6363 and more", "255 in hex"] {
            #expect(module.instantResults(for: query).isEmpty, "\(query)")
        }
    }

    @MainActor
    @Test func theSwatchIsOfAColorThatCanBeShown() throws {
        let rows = ColorModule().instantResults(for: "oklch(0.8 0.4 145)")
        guard case .swatch(let red, let green, let blue, _) = try #require(rows.first).icon else {
            Issue.record("No swatch")
            return
        }
        #expect([red, green, blue].allSatisfy { (0...1).contains($0) })
    }
}
