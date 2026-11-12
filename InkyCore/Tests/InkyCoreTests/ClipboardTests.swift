import AppKit
import Foundation
import ImageIO
import Testing
@testable import InkyCore

/// A folder of its own for a test, gone when the test is.
private final class Scratch {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("inky-clipboard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func text(_ text: String, at date: Date = .now, from source: String? = nil) -> ClipCapture {
    var capture = ClipCapture.text(text, fileExists: { _ in false })!
    capture.date = date
    capture.sourceName = source
    return capture
}

/// An image of one color, encoded as `type`.
private func image(width: Int = 40, height: Int = 20, gray: CGFloat = 0.5, type: String = "public.png") -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Suite struct ClipClassifierTests {
    private func kind(_ text: String, existing: Set<String> = []) -> ClipKind {
        ClipClassifier.kind(of: text) { existing.contains($0) }
    }

    @Test func tellsColorsFromNumbers() {
        for color in ["#2563EB", "#fff", "#ff636380", "rgb(255, 99, 99)", "oklch(0.7 0.19 23)", "  #2563eb;\n"] {
            #expect(kind(color) == .color, "\(color)")
        }
        // The number of an issue, a word, a sentence with a color in it.
        for other in ["#123", "#1234", "red", "use #2563EB here", "#nofilter"] {
            #expect(kind(other) != .color, "\(other)")
        }
    }

    @Test func tellsLinksFromTextWithLinksInIt() {
        for link in [
            "https://kagi.com/search?q=liquid+glass+macos", "http://localhost:3000", "www.example.com/page",
            "raycast://extensions/x", "mailto:someone@example.com", "ssh://git@example.com/repo.git",
        ] {
            #expect(kind(link) == .link, "\(link)")
        }
        for other in ["see https://example.com", "https://a.com https://b.com", "example.com", "note: this", "C://", "a://"] {
            #expect(kind(other) != .link, "\(other)")
        }
    }

    @Test func aPathIsOneThatLeadsSomewhere() {
        let home = NSHomeDirectory()
        #expect(kind("~/Projects/inky", existing: [home + "/Projects/inky"]) == .path)
        #expect(kind("/usr/local/bin", existing: ["/usr/local/bin"]) == .path)
        #expect(kind("/help") == .text)
        #expect(kind("/api/v1/users") == .text)
        #expect(kind("/", existing: ["/"]) == .text)
    }

    @Test func whatIsNotAColorALinkOrAPathIsText() {
        for text in [
            "const add = (a, b) => a + b;",
            "SELECT id, title FROM clips WHERE kind = 'text';",
            "Thanks, that works for me. I'll send the draft tonight.",
            "Musterstraße 12\n18055 Rostock",
        ] {
            #expect(kind(text) == .text, "\(text)")
        }
        // Only a short text on one line is looked at more closely, however
        // much space is around it.
        let spaces = String(repeating: " \n", count: 100_000)
        #expect(kind(spaces + "#2563EB" + spaces) == .color)
        #expect(kind(String(repeating: "#2563EB ", count: 100_000)) == .text)
        #expect(kind(String(repeating: "a", count: 200)) == .text)
        #expect(kind("https://example.com/" + String(repeating: "a", count: 180)) == .link)
        #expect(kind("https://example.com/" + String(repeating: "a", count: 181)) == .text)
    }

    @Test func titlesAreTheFirstLineThatSaysSomething() {
        #expect(ClipClassifier.title(of: "\n\n   let   x = 1  \nlet y = 2", kind: .text) == "let x = 1")
        #expect(ClipClassifier.title(of: "https://www.kagi.com/search?q=glass", kind: .link) == "kagi.com/search?q=glass")
        #expect(ClipClassifier.title(of: "https://example.com/", kind: .link) == "example.com")
        #expect(ClipClassifier.title(of: "raycast://extensions", kind: .link) == "raycast://extensions")
        #expect(ClipClassifier.title(of: String(repeating: "a", count: 1000), kind: .text).count == ClipClassifier.maxTitleLength)
        #expect(ClipClassifier.title(of: "\u{A0}\u{A0}\n\t\r\n  first   words\u{2028}second", kind: .text) == "first words")
        let words = String(repeating: "word  ", count: 200_000)
        #expect(ClipClassifier.title(of: words, kind: .text) == String(repeating: "word ", count: 48))
    }

    @Test func nothingIsNotACopy() {
        #expect(ClipCapture.text("") == nil)
        #expect(ClipCapture.text("  \n\t ") == nil)
        #expect(ClipCapture.files([]) == nil)
        #expect(ClipCapture.files(["/a/Report.pdf"])?.title == "Report.pdf")
        #expect(ClipCapture.files(["/a/Report.pdf", "/a/b.txt", "/a/c.txt"])?.title == "Report.pdf and 2 more")
    }

    @Test func aLinkIsPastedAsWhatItSays() {
        let flavors = ["public.rtf": Data("rtf".utf8)]
        #expect(ClipCapture.text("Some words", flavors: flavors)?.flavors == flavors)
        #expect(ClipCapture.text("https://example.com", flavors: flavors)?.flavors.isEmpty == true)
        #expect(ClipCapture.text("#2563EB", flavors: flavors)?.flavors.isEmpty == true)
    }
}

@Suite struct ClipboardFormatTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func agesAreShort() {
        let now = date(2026, 11, 11, 14, 31)
        let locale = Locale(identifier: "en_US")
        func age(_ date: Date) -> String {
            ClipboardFormat.age(of: date, now: now, calendar: calendar, locale: locale)
        }
        #expect(age(now.addingTimeInterval(-20)) == "now")
        #expect(age(now.addingTimeInterval(-60)) == "1 min")
        #expect(age(now.addingTimeInterval(-59 * 60)) == "59 min")
        #expect(age(now.addingTimeInterval(-3600)) == "1 h")
        #expect(age(now.addingTimeInterval(-23.5 * 3600)) == "23 h")
        #expect(age(now.addingTimeInterval(-3 * 86400)) == "3 d")
        #expect(age(date(2026, 10, 3)) == "Oct 3")
        #expect(age(date(2025, 12, 24)) == "Dec 24, 2025")
        // A clock that was set back does not make a copy one from the future.
        #expect(age(now.addingTimeInterval(30)) == "now")
    }

    @Test func sectionsGoByDaysNotHours() {
        let now = date(2026, 11, 11, 0, 30)
        func section(_ date: Date) -> String {
            ClipboardFormat.section(of: date, now: now, calendar: calendar)
        }
        #expect(section(date(2026, 11, 11, 0, 10)) == "Today")
        // An hour ago, and yesterday all the same.
        #expect(section(date(2026, 11, 10, 23, 30)) == "Yesterday")
        #expect(section(date(2026, 11, 9)) == "Previous 7 Days")
        #expect(section(date(2026, 11, 4)) == "Previous 7 Days")
        #expect(section(date(2026, 11, 3)) == "Previous 30 Days")
        #expect(section(date(2026, 10, 12)) == "Previous 30 Days")
        #expect(section(date(2026, 10, 11)) == "Older")
    }

    @Test func retentionCountsBackFromNow() {
        let now = date(2026, 11, 11)
        func cutoff(_ retention: ClipboardRetention) -> Date? {
            retention.cutoff(from: now, calendar: calendar)
        }
        #expect(cutoff(.day) == date(2026, 11, 10))
        #expect(cutoff(.week) == date(2026, 11, 4))
        #expect(cutoff(.month) == date(2026, 10, 12))
        #expect(cutoff(.threeMonths) == date(2026, 8, 11))
        #expect(cutoff(.sixMonths) == date(2026, 5, 11))
        #expect(cutoff(.year) == date(2025, 11, 11))
        #expect(cutoff(.forever) == nil)
        // Every choice is stored by a name that reads back.
        for retention in ClipboardRetention.allCases {
            #expect(ClipboardRetention(rawValue: retention.rawValue) == retention)
        }
    }
}

@Suite struct ClipboardStoreTests {
    private let scratch = Scratch()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() -> ClipboardStore {
        ClipboardStore(directory: scratch.url)
    }

    /// Records `texts`, each a minute after the one before.
    private func fill(_ store: ClipboardStore, _ texts: [String]) async {
        for (offset, entry) in texts.enumerated() {
            await store.record(text(entry, at: start.addingTimeInterval(Double(offset) * 60)))
        }
    }

    private func titles(_ store: ClipboardStore, _ search: String = "", filter: ClipFilter = .all, since: Date? = nil) async -> [String] {
        await store.snapshot(ClipQuery(text: search, filter: filter, since: since), limit: 100).clips.map(\.title)
    }

    @Test func listsTheNewestFirst() async {
        let store = makeStore()
        await fill(store, ["first", "second", "third"])
        #expect(await titles(store) == ["third", "second", "first"])
    }

    @Test func theSameThingCopiedAgainMovesUp() async {
        let store = makeStore()
        await fill(store, ["first", "second"])
        let again = await store.record(text("first", at: start.addingTimeInterval(600), from: "Notes"))
        let snapshot = await store.snapshot(ClipQuery(), limit: 100)
        #expect(snapshot.clips.map(\.title) == ["first", "second"])
        #expect(snapshot.clips[0].id == again)
        #expect(snapshot.clips[0].copies == 2)
        #expect(snapshot.clips[0].sourceName == "Notes")
        #expect(snapshot.clips[0].firstCopied == start)
        #expect(snapshot.clips[0].lastCopied == start.addingTimeInterval(600))
        #expect(snapshot.total == 2)
    }

    @Test func findsWordsAnywhereInAnyOrder() async {
        let store = makeStore()
        await fill(store, [
            "Design sync moved to Thursday, 10:00",
            "let panel = NSPanel(contentRect: frame)",
            "https://kagi.com/search?q=liquid+glass+macos",
            "Thanks, that works for me. I'll send the draft tonight.",
            "Say \"hello\" 100% of_the time",
        ])
        #expect(await titles(store, "thursday") == ["Design sync moved to Thursday, 10:00"])
        #expect(await titles(store, "URSD") == ["Design sync moved to Thursday, 10:00"])
        #expect(await titles(store, "moved design") == ["Design sync moved to Thursday, 10:00"])
        #expect(await titles(store, "glass kagi") == ["kagi.com/search?q=liquid+glass+macos"])
        #expect(await titles(store, "nspanel(") == ["let panel = NSPanel(contentRect: frame)"])
        #expect(await titles(store, "design draft").isEmpty)
        #expect(await titles(store, "zzzz").isEmpty)
        // Shorter than what the index knows.
        #expect(await titles(store, "10") == ["Say \"hello\" 100% of_the time", "Design sync moved to Thursday, 10:00"])
        #expect(await titles(store, "me draft") == ["Thanks, that works for me. I'll send the draft tonight."])
        // What means something to SQLite is looked for as it is written.
        #expect(await titles(store, "\"hello\"") == ["Say \"hello\" 100% of_the time"])
        #expect(await titles(store, "0%") == ["Say \"hello\" 100% of_the time"])
        #expect(await titles(store, "f_") == ["Say \"hello\" 100% of_the time"])
        #expect(await titles(store, "_").count == 1)
        #expect(await titles(store, "%").count == 1)
        #expect(await titles(store, "AND OR NOT").isEmpty)
    }

    @Test func findsWhatIsDeepInALongText() async {
        let store = makeStore()
        let long = "start\n" + String(repeating: "lorem ipsum dolor sit amet\n", count: 2000) + "needle at the end"
        await fill(store, [long, "other"])
        #expect(await titles(store, "needle") == ["start"])
        let content = await store.content(of: await store.snapshot(ClipQuery(text: "needle"), limit: 1).clips[0].id)
        #expect(content?.isTruncated == true)
        #expect(content?.characters == long.count)
        #expect(content?.lines == 2002)
        #expect(content?.text?.hasPrefix("start\nlorem") == true)
    }

    @Test func narrowsDownByKindAndTime() async {
        let store = makeStore()
        await fill(store, ["plain words", "const a = (b) => b;", "https://example.com", "#2563EB"])
        var picture = ClipCapture.image(image(), type: "public.png")
        picture.date = start.addingTimeInterval(240)
        await store.record(picture)
        var files = ClipCapture.files(["/tmp/a.txt"])!
        files.date = start.addingTimeInterval(300)
        await store.record(files)

        #expect(await titles(store, filter: .text) == ["const a = (b) => b;", "plain words"])
        #expect(await titles(store, filter: .links) == ["example.com"])
        #expect(await titles(store, filter: .colors) == ["#2563EB"])
        #expect(await titles(store, filter: .images) == ["Image"])
        #expect(await titles(store, filter: .files) == ["a.txt"])
        #expect(await titles(store, "example", filter: .text).isEmpty)

        let snapshot = await store.snapshot(ClipQuery(), limit: 100)
        #expect(snapshot.total == 6)
        #expect(ClipFilter.allCases.map(snapshot.count) == [6, 2, 1, 1, 1, 1])

        let recent = await store.snapshot(ClipQuery(since: start.addingTimeInterval(90)), limit: 100)
        #expect(recent.clips.count == 4)
        #expect(recent.count(.text) == 0)
        #expect(recent.count(.links) == 1)
    }

    @Test func handsOutTheHistoryInPages() async {
        let store = makeStore()
        // Several at the same moment, as when they are read in from elsewhere.
        for index in 0..<25 {
            await store.record(text("entry \(index)", at: start.addingTimeInterval(Double(index / 5))))
        }
        var snapshot = await store.snapshot(ClipQuery(), limit: 10)
        var seen = snapshot.clips
        #expect(snapshot.hasMore)
        while snapshot.hasMore, let last = seen.last {
            let page = await store.page(ClipQuery(), after: last, limit: 10)
            seen += page.clips
            snapshot.hasMore = page.hasMore
        }
        #expect(seen.count == 25)
        #expect(Set(seen.map(\.id)).count == 25)
        #expect(seen.map(\.lastCopied) == seen.map(\.lastCopied).sorted(by: >))
    }

    @Test func pinnedEntriesAreListedApartAndFoundByName() async {
        let store = makeStore()
        await fill(store, ["Musterstraße 12, 18055 Rostock", "ssh deploy@staging.example.com", "other"])
        let all = await store.snapshot(ClipQuery(), limit: 100).clips
        await store.setPinned(all[2].id, true, at: start)
        await store.setPinned(all[1].id, true, at: start.addingTimeInterval(1))
        await store.rename(all[2].id, to: "  Office address ")

        var snapshot = await store.snapshot(ClipQuery(), limit: 100)
        #expect(snapshot.pins.map(\.displayTitle) == ["Office address", "ssh deploy@staging.example.com"])
        #expect(snapshot.pinned.map(\.id) == snapshot.pins.map(\.id))
        #expect(snapshot.clips.map(\.title) == ["other"])
        #expect(snapshot.total == 3)

        // By its name, by what it holds, and whenever it was copied.
        snapshot = await store.snapshot(ClipQuery(text: "office", since: start.addingTimeInterval(3600)), limit: 100)
        #expect(snapshot.pinned.map(\.displayTitle) == ["Office address"])
        #expect(snapshot.pins.count == 2)
        #expect(snapshot.clips.isEmpty)
        snapshot = await store.snapshot(ClipQuery(text: "rostock"), limit: 100)
        #expect(snapshot.pinned.map(\.displayTitle) == ["Office address"])
        snapshot = await store.snapshot(ClipQuery(filter: .links), limit: 100)
        #expect(snapshot.pinned.isEmpty)

        // A name that is taken away is not found anymore.
        await store.rename(all[2].id, to: " ")
        snapshot = await store.snapshot(ClipQuery(text: "office"), limit: 100)
        #expect(snapshot.pinned.isEmpty)
        #expect(await store.clip(all[2].id)?.name == nil)

        // Letting go of it puts it back among the rest, without its name.
        await store.rename(all[1].id, to: "Staging")
        await store.setPinned(all[1].id, false)
        let clip = await store.clip(all[1].id)
        #expect(clip?.isPinned == false)
        #expect(clip?.name == nil)
        #expect(await titles(store).contains("ssh deploy@staging.example.com"))
    }

    @Test func oldEntriesGoAndPinnedOnesStay() async {
        let store = makeStore()
        await fill(store, ["old", "old and pinned", "new"])
        let all = await store.snapshot(ClipQuery(), limit: 100).clips
        await store.setPinned(all[1].id, true)

        #expect(await store.prune(before: start.addingTimeInterval(90)) == 1)
        let snapshot = await store.snapshot(ClipQuery(), limit: 100)
        #expect(snapshot.clips.map(\.title) == ["new"])
        #expect(snapshot.pins.map(\.title) == ["old and pinned"])
        // What went is not found anymore either.
        #expect(await titles(store, "old").isEmpty)
        #expect(await store.snapshot(ClipQuery(text: "old"), limit: 100).pinned.count == 1)

        await store.clear()
        #expect(await store.statistics().entries == 1)
        await store.clear(includingPinned: true)
        #expect(await store.statistics().entries == 0)
    }

    @Test func keepsImagesAsFilesAndTakesThemAlong() async throws {
        let store = makeStore()
        let png = image(width: 1200, height: 600)
        let id = try #require(await store.record(.image(png, type: "public.png", from: "Safari")))
        let clip = try #require(await store.clip(id))
        #expect(clip.title == "Image from Safari")
        #expect(clip.width == 1200)
        #expect(clip.height == 600)

        let payload = try #require(await store.payload(of: id))
        let stored = try #require(payload.imageURL)
        #expect(try Data(contentsOf: stored) == png)
        #expect(payload.imageType == "public.png")

        // The copy to show is small.
        let preview = try #require(store.previewURL(of: clip))
        let source = try #require(CGImageSourceCreateWithURL(preview as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyPixelWidth] as? Int == 640)
        #expect(properties?[kCGImagePropertyPixelHeight] as? Int == 320)

        // The same image again is the same entry and the same file.
        #expect(await store.record(.image(png, type: "public.png")) == id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).count == 2)

        await store.delete(id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).isEmpty)
    }

    @Test func keepsTIFFAsPNG() async throws {
        let store = makeStore()
        let tiff = image(width: 300, height: 200, type: "public.tiff")
        let id = try #require(await store.record(.image(tiff, type: "public.tiff")))
        let payload = try #require(await store.payload(of: id))
        #expect(payload.imageType == "public.png")
        #expect(payload.imageURL?.pathExtension == "png")
        let clip = try #require(await store.clip(id))
        #expect(clip.width == 300)
        #expect(clip.byteCount > 0)
        #expect(clip.byteCount < tiff.count)

        // What no entry names is swept away, and what one does stays.
        let stray = store.imageDirectory.appendingPathComponent("stray.png")
        try Data("x".utf8).write(to: stray)
        await store.removeStrayImages()
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).count == 2)
    }

    @Test func anImageCopiedTwiceAtOnceIsOneEntry() async throws {
        let store = makeStore()
        let png = image(width: 600, height: 400)
        async let first = store.record(.image(png, type: "public.png"))
        async let second = store.record(.image(png, type: "public.png"))
        let ids = await [first, second]
        #expect(ids[0] != nil && ids[0] == ids[1])
        #expect(await store.snapshot(ClipQuery(), limit: 10).clips.map(\.copies) == [2])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).count == 2)
    }

    @Test func aLargeImageDoesNotHoldUpTheHistory() async throws {
        let store = makeStore()
        await fill(store, ["already there"])
        let tiff = image(width: 6000, height: 4000, type: "public.tiff")
        let recording = Task {
            let id = await store.record(.image(tiff, type: "public.tiff"))
            return (id: id, at: ContinuousClock.now)
        }
        try await Task.sleep(for: .milliseconds(5))
        // Answered while the image is still being written.
        #expect(await titles(store) == ["already there"])
        let answered = ContinuousClock.now
        let recorded = await recording.value
        #expect(recorded.id != nil)
        #expect(answered < recorded.at)
        #expect(await titles(store).count == 2)
    }

    @Test func keepsTheFormattingOfTheLatestCopy() async throws {
        let store = makeStore()
        var capture = text("Some words")
        capture.flavors = ["public.rtf": Data("{\\rtf1 Some words}".utf8), "public.html": Data("<b>Some words</b>".utf8)]
        let id = try #require(await store.record(capture))
        #expect(await store.clip(id)?.hasFormatting == true)
        #expect(await store.payload(of: id)?.flavors == capture.flavors)
        #expect(await store.payload(of: id)?.text == "Some words")

        #expect(await store.record(text("Some words")) == id)
        #expect(await store.clip(id)?.hasFormatting == false)
        #expect(await store.payload(of: id)?.flavors.isEmpty == true)
    }

    @Test func staysWhereItIsKept() async throws {
        var store: ClipboardStore? = makeStore()
        await fill(store!, ["kept across launches"])
        let first = await store!.snapshot(ClipQuery(), limit: 10).clips
        store = nil
        let reopened = makeStore()
        #expect(await reopened.snapshot(ClipQuery(), limit: 10).clips == first)
        #expect(await titles(reopened, "launches") == ["kept across launches"])
        #expect(await reopened.statistics().bytes > 0)
    }

    @Test func anUnreadableHistoryAndItsImagesAreLeftAlone() async throws {
        let original = Data("this is not a database, and long enough to be read as one".utf8)
        let file = scratch.url.appendingPathComponent("history.sqlite")
        try original.write(to: file)
        let images = scratch.url.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let imageFile = images.appendingPathComponent("previous.png")
        let previousImage = image(width: 20, height: 10)
        try previousImage.write(to: imageFile)
        let previousBackup = scratch.url.appendingPathComponent("history.unreadable.sqlite")
        try original.write(to: previousBackup)
        let store = makeStore()
        #expect(!store.isPersistent)
        await fill(store, ["after"])
        #expect(await titles(store) == ["after"])
        await store.removeStrayImages()
        #expect(try Data(contentsOf: file) == original)
        #expect(try Data(contentsOf: previousBackup) == original)
        #expect(try Data(contentsOf: imageFile) == previousImage)
        let id = try #require(await store.record(.image(previousImage, type: "public.png")))
        let temporaryImage = try #require(await store.payload(of: id)?.imageURL)
        #expect(temporaryImage.deletingLastPathComponent() != images)
        await store.delete(id)
        #expect(try Data(contentsOf: imageFile) == previousImage)
    }

    @Test func preservesTextContainingNullCharacters() async throws {
        let store = makeStore()
        let value = "Before\0After café 🐙"
        let id = try #require(await store.record(text(value)))
        #expect(await store.payload(of: id)?.text == value)
    }

    @Test func aLockedHistoryIsNotReplaced() async throws {
        var original: ClipboardStore? = makeStore()
        await fill(original!, ["keep me"])
        original = nil
        let file = scratch.url.appendingPathComponent("history.sqlite")
        let lock = try SQLiteDatabase(path: file.path)
        try lock.execute("PRAGMA journal_mode = DELETE; BEGIN EXCLUSIVE")
        defer { try? lock.execute("ROLLBACK") }
        let second = makeStore()
        // Opening another connection must leave the live database in place.
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!second.isPersistent)
        try lock.execute("ROLLBACK")
        #expect(await titles(makeStore()) == ["keep me"])
    }

    @Test func whatWasKeptAsCodeIsText() async throws {
        var store: ClipboardStore? = makeStore()
        await fill(store!, ["let x = 1", "some words"])
        store = nil
        let database = try SQLiteDatabase(path: scratch.url.appendingPathComponent("history.sqlite").path)
        try database.execute("UPDATE clips SET kind = 'code' WHERE title = 'let x = 1'")

        let reopened = makeStore()
        let snapshot = await reopened.snapshot(ClipQuery(filter: .text), limit: 10)
        #expect(snapshot.clips.map(\.title) == ["some words", "let x = 1"])
        #expect(snapshot.counts == [.text: 2])
    }

    @Test func aNewerHistoryIsLeftForTheVersionThatWroteIt() async throws {
        let file = scratch.url.appendingPathComponent("history.sqlite")
        let database = try SQLiteDatabase(path: file.path)
        try database.execute("PRAGMA user_version = 2")
        let store = makeStore()
        #expect(!store.isPersistent)
        await fill(store, ["only this session"])
        #expect(await titles(store) == ["only this session"])
        #expect(try database.query("PRAGMA user_version") { $0.int(0) } == [2])
    }

    @Test func manyEntriesAreListedAndSearchedQuickly() async {
        let store = makeStore()
        for index in 0..<4000 {
            await store.record(text(
                "Entry number \(index) with some words in it to make it a bit longer, id-\(index * 7919 % 4001)",
                at: start.addingTimeInterval(Double(index))
            ))
        }
        // Through the index, not by reading four thousand texts.
        #expect(await store.isIndexed)
        let clock = ContinuousClock()
        var found = 0
        let listing = await clock.measure {
            for _ in 0..<20 { found = await store.snapshot(ClipQuery(), limit: 200).clips.count }
        }
        #expect(found == 200)
        let searching = await clock.measure {
            for _ in 0..<20 { found = await store.snapshot(ClipQuery(text: "id-3999"), limit: 200).clips.count }
        }
        #expect(found == 1)
        // Far more room than either needs, so that a slow machine passes.
        print("clipboard: 20 listings in \(listing), 20 searches in \(searching)")
        #expect(listing < .seconds(2), "\(listing)")
        #expect(searching < .seconds(2), "\(searching)")
    }
}

@MainActor
@Suite struct ClipboardHistoryTests {
    private let scratch = Scratch()
    /// One of its own, so that the user's clipboard is neither read nor written.
    private let pasteboard = NSPasteboard.withUniqueName()

    private func makeHistory() -> ClipboardHistory {
        let history = ClipboardHistory(store: ClipboardStore(directory: scratch.url), pasteboard: pasteboard)
        history.start()
        return history
    }

    /// Lets what `check` started finish.
    private func settle(_ history: ClipboardHistory, from revision: Int) async {
        for _ in 0..<200 where history.revision == revision {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func copy(_ history: ClipboardHistory, _ write: (NSPasteboard) -> Void) async {
        let revision = history.revision
        pasteboard.clearContents()
        write(pasteboard)
        history.check()
        await settle(history, from: revision)
    }

    private func clips(_ history: ClipboardHistory) async -> [Clip] {
        await history.store.snapshot(ClipQuery(), limit: 100).clips
    }

    @Test func keepsWhatIsCopiedFromNowOn() async {
        pasteboard.clearContents()
        pasteboard.setString("copied before", forType: .string)
        let history = makeHistory()
        defer { history.stop(); pasteboard.releaseGlobally() }
        history.check()
        #expect(await clips(history).isEmpty)

        await copy(history) { $0.setString("copied now", forType: .string) }
        await copy(history) {
            $0.setString("with formatting", forType: .string)
            $0.setData(Data("{\\rtf1 with formatting}".utf8), forType: .rtf)
        }
        let kept = await clips(history)
        #expect(kept.map(\.title) == ["with formatting", "copied now"])
        #expect(kept.map(\.hasFormatting) == [true, false])
        #expect(history.revision == 2)

        // Nothing changed, nothing is read.
        history.check()
        #expect(history.revision == 2)
    }

    @Test func leavesWhatOnlyPassesThrough() async {
        let history = makeHistory()
        defer { history.stop(); pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("typed by a text expander", forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        history.check()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await clips(history).isEmpty)

        // A password manager's copy is left out unless asked for.
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        history.check()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await clips(history).isEmpty)
    }

    @Test func keepsPasswordsOnlyWhenAskedTo() async throws {
        let history = makeHistory()
        defer { history.stop(); pasteboard.releaseGlobally() }
        history.keepsConcealed = true
        await copy(history) {
            $0.setString("hunter2", forType: .string)
            $0.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        await copy(history) {
            $0.setString("correct horse", forType: .string)
            $0.setString("", forType: NSPasteboard.PasteboardType("com.agilebits.onepassword"))
        }
        let kept = await clips(history)
        #expect(Set(kept.map(\.title)) == ["hunter2", "correct horse"])
        #expect(kept.allSatisfy { $0.isConcealed })

        // Put back, they are marked as confidential again, so that other
        // clipboard managers leave them out too. With formatting or without.
        for asPlainText in [false, true] {
            pasteboard.clearContents()
            try await history.copy(kept[0], asPlainText: asPlainText)
            #expect(pasteboard.string(forType: .string) == kept[0].title)
            #expect(pasteboard.types?.contains(Pasteboard.concealed) == true)
        }

        // Pinned ones stay when they are no longer to be kept.
        await history.setPinned(kept.first { $0.title == "hunter2" }!, true)
        let revision = history.revision
        history.keepsConcealed = false
        await settle(history, from: revision)
        let left = await history.store.snapshot(ClipQuery(), limit: 100)
        #expect(left.clips.isEmpty)
        #expect(left.pins.map(\.title) == ["hunter2"])
    }

    @Test func knowsWhatInkyCopiedItself() async {
        let history = makeHistory()
        defer { history.stop(); pasteboard.releaseGlobally() }
        await copy(history) {
            $0.setString("1 540", forType: .string)
            $0.setString("", forType: Pasteboard.copiedByInky)
        }
        #expect(await clips(history).first?.sourceName == "Inky")
    }

    @Test func tellsFilesAndImagesFromText() async throws {
        let history = makeHistory()
        defer { history.stop(); pasteboard.releaseGlobally() }

        let file = scratch.url.appendingPathComponent("Report.pdf")
        try Data("pdf".utf8).write(to: file)
        await copy(history) { $0.writeObjects([file as NSURL]) }

        let png = image()
        // As a browser copies an image: with its address.
        await copy(history) {
            $0.setData(png, forType: .png)
            $0.setString("https://example.com/cat.png", forType: .string)
        }
        // As a spreadsheet copies cells: with a picture of them.
        await copy(history) {
            $0.setString("12\t34", forType: .string)
            $0.setData(png, forType: .png)
        }
        let kept = await clips(history)
        #expect(kept.map(\.kind) == [.text, .image, .file])
        #expect(kept[2].title == "Report.pdf")
        #expect(kept[2].location == file.path)
        #expect(kept[1].width == 40)
    }

    @Test func putsAnEntryBackWithoutCountingItAsNew() async throws {
        let history = makeHistory()
        defer { history.stop(); pasteboard.releaseGlobally() }
        await copy(history) {
            $0.setString("first", forType: .string)
            $0.setData(Data("<b>first</b>".utf8), forType: .html)
        }
        await copy(history) { $0.setString("second", forType: .string) }
        let first = try #require(await clips(history).last)

        try await history.copy(first)
        #expect(pasteboard.string(forType: .string) == "first")
        #expect(pasteboard.data(forType: .html) == Data("<b>first</b>".utf8))
        // Only what came marked as confidential goes back marked.
        #expect(pasteboard.types?.contains(Pasteboard.concealed) == false)
        history.check()
        try? await Task.sleep(for: .milliseconds(50))
        var kept = await clips(history)
        // It moved up, and is still one entry.
        #expect(kept.map(\.title) == ["first", "second"])
        #expect(kept[0].copies == 2)

        try await history.copy(kept[0], asPlainText: true)
        #expect(pasteboard.string(forType: .string) == "first")
        #expect(pasteboard.data(forType: .html) == nil)

        // An image is handed out as the other kinds of image too.
        let png = image()
        await copy(history) { $0.setData(png, forType: .png) }
        kept = await clips(history)
        try await history.copy(kept[0])
        #expect(pasteboard.data(forType: .png) == png)
        #expect(NSImage(data: try #require(pasteboard.data(forType: .tiff)))?.representations.first?.pixelsWide == 40)

        // A file that is gone cannot be pasted, and says so.
        let file = scratch.url.appendingPathComponent("gone.txt")
        try Data("x".utf8).write(to: file)
        await copy(history) { $0.writeObjects([file as NSURL]) }
        kept = await clips(history)
        try FileManager.default.removeItem(at: file)
        await #expect(throws: InkyError.self) { try await history.copy(kept[0]) }

        await history.delete(kept[0])
        await #expect(throws: InkyError.self) { try await history.copy(kept[0]) }
    }

    @Test func stopsKeepingWhenStopped() async {
        let history = makeHistory()
        defer { pasteboard.releaseGlobally() }
        history.stop()
        pasteboard.clearContents()
        pasteboard.setString("copied while off", forType: .string)
        history.check()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await clips(history).isEmpty)

        // Turned on again, it does not pick up what it missed.
        history.start()
        history.check()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await clips(history).isEmpty)
        history.stop()
    }

    @Test func letsGoOfWhatIsTooOldWhenAskedToKeepLess() async {
        let history = makeHistory()
        defer { history.stop(); pasteboard.releaseGlobally() }
        var old = ClipCapture.text("from last month")!
        old.date = Date.now.addingTimeInterval(-40 * 86400)
        await history.store.record(old)
        await copy(history) { $0.setString("from today", forType: .string) }
        #expect(await clips(history).count == 2)

        let revision = history.revision
        history.retention = .week
        await settle(history, from: revision)
        #expect(await clips(history).map(\.title) == ["from today"])
    }

    @Test func findsTheKeyThatPastes() {
        // On the layouts tests run with, V is where it is printed. What
        // matters is that the layout is asked and answers.
        #expect(KeyboardPaste.keyCode(for: "v") != nil)
    }
}
