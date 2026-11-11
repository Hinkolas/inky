#if DEBUG
import AppKit
import InkyCore

/// Made-up copies of every kind and age, for looking at the clipboard
/// history without anyone's real one: `--clipboard-samples`, with `--data`.
enum ClipboardSamples {
    static func fill(_ store: ClipboardStore) async {
        guard await store.statistics().entries == 0 else { return }
        let now = Date.now

        func record(_ capture: ClipCapture?, _ source: String?, minutes: Double, pinnedAs name: String? = nil) async {
            guard var capture else { return }
            capture.sourceName = source
            capture.date = now.addingTimeInterval(-minutes * 60)
            guard let id = await store.record(capture) else { return }
            if let name {
                await store.setPinned(id, true, at: capture.date)
                await store.rename(id, to: name)
            }
        }

        let code = """
            let panel = NSPanel(
              contentRect: frame,
              styleMask: [.nonactivatingPanel],
              backing: .buffered,
              defer: false
            )
            panel.level = .floating
            """
        let formatted = ClipCapture.text(
            "Thanks, that works for me. I'll send the draft tonight.",
            flavors: ["public.html": Data("<p>Thanks, that works for me. I'll send the <b>draft</b> tonight.</p>".utf8)]
        )

        await record(.text("Musterstraße 12\n18055 Rostock\nGermany"), "Notes", minutes: 9000, pinnedAs: "Office address")
        await record(.text("Best regards\nNicholas"), "Mail", minutes: 8000, pinnedAs: "Email signature")
        await record(.text("ssh deploy@staging.example.com"), "Terminal", minutes: 7000, pinnedAs: "Staging server")

        await record(.text(code), "Xcode", minutes: 1)
        await record(.text("https://kagi.com/search?q=liquid+glass+macos"), "Safari", minutes: 6)
        await record(.image(picture(width: 2560, height: 1600), type: "public.png", from: "Safari"), "Safari", minutes: 11)
        await record(.text("#2563EB"), "Figma", minutes: 12)
        await record(.text("Design sync moved to Thursday, 10:00"), "Messages", minutes: 60)
        await record(.text("~/Library/Application Support"), "Terminal", minutes: 120)
        await record(formatted, "Mail", minutes: 180)
        await record(.files(["/Applications/Safari.app"]), "Finder", minutes: 200)
        await record(.files([NSHomeDirectory() + "/Downloads", NSHomeDirectory() + "/Documents"]), "Finder", minutes: 260)
        await record(.text("oklch(0.7 0.19 23)"), "Zed", minutes: 300)
        await record(.text("SELECT id, title FROM clips WHERE kind = 'text';"), "TablePlus", minutes: 1500)
        await record(.image(picture(width: 800, height: 1200, warm: true), type: "public.tiff", from: "Preview"), "Preview", minutes: 1600)
        await record(.text("mailto:hello@example.com"), "Mail", minutes: 3000)
        for index in 1...240 {
            await record(
                .text("Note \(index): something that was copied a while ago and is still here to be found"),
                index.isMultiple(of: 3) ? "Notes" : "Safari",
                minutes: 4000 + Double(index) * 190
            )
        }
    }

    /// A picture with enough going on to tell it from another.
    private static func picture(width: Int, height: Int, warm: Bool = false) -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return Data() }
        let colors = (warm ? [NSColor.hex(0xFF7A59), .hex(0xB02ACB)] : [NSColor.hex(0x8DAEFB), .hex(0xF4B5A2)]).map(\.cgColor)
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: width, y: height), options: []
            )
        }
        context.setFillColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        context.fillEllipse(in: CGRect(x: width / 5, y: height / 4, width: width / 3, height: width / 3))

        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, (warm ? "public.tiff" : "public.png") as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
#endif
