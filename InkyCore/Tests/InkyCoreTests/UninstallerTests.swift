import Foundation
import Testing
@testable import InkyCore

@Suite struct LeftoverMatcherTests {
    private let pako = ApplicationInfo(
        path: "/Applications/Pako.app", name: "Pako", bundleID: "io.github.hinkolas.pako"
    )

    private func matcher(_ app: ApplicationInfo, installed: [ApplicationInfo] = []) -> LeftoverMatcher {
        LeftoverMatcher(app: app, installed: [app] + installed)
    }

    @Test func findsWhatGoesByTheIdentifier() {
        let matcher = matcher(pako)
        for name in [
            "io.github.hinkolas.pako",
            "io.github.hinkolas.pako.plist",
            "io.github.hinkolas.pako.savedState",
            "io.github.hinkolas.pako.binarycookies",
            "io.github.hinkolas.pako.helper.plist",
            "io.github.hinkolas.pako.ShipIt",
            "IO.GitHub.Hinkolas.Pako.plist",
            "io.github.hinkolas.pako.0A1B2C3D-0000-1111-2222-333344445555.plist",
            "group.io.github.hinkolas.pako",
            "AB12CD34EF.io.github.hinkolas.pako",
            "AB12CD34EF.group.io.github.hinkolas.pako.shared",
        ] {
            #expect(matcher.matches(name, byName: false), "\(name)")
        }
    }

    @Test func leavesWhatOnlyLooksLikeTheIdentifier() {
        let matcher = matcher(pako)
        for name in [
            "io.github.hinkolas.pakora.plist",
            "io.github.hinkolas",
            "io.github.hinkolas.plist",
            "group.io.github.hinkolas",
            ".DS_Store",
        ] {
            #expect(!matcher.matches(name, byName: true), "\(name)")
        }
        // Something in front of it that is neither a team nor a group. These
        // end in the name, which is enough only where a name counts.
        for name in ["notio.github.hinkolas.pako", "AB12CD34E.io.github.hinkolas.pako"] {
            #expect(!matcher.matches(name, byName: false), "\(name)")
        }
    }

    @Test func findsWhatGoesByTheName() {
        let matcher = matcher(pako)
        for name in ["Pako", "pako", "Pako.plist", "Pako.log", "com.electron.pako", "com.electron.pako.plist", "dev.example.Pako.savedState"] {
            #expect(matcher.matches(name, byName: true), "\(name)")
            // Where only the identifier counts, a name is not enough.
            #expect(!matcher.matches(name, byName: false), "\(name)")
        }
        for name in ["Pako Helper", "Pakora", "MyPako", "pako.electron.com", "electron.pako", "com.electron.pako.helper.plist"] {
            #expect(!matcher.matches(name, byName: true), "\(name)")
        }
    }

    @Test func knowsTheOtherNamesOfAnApplication() {
        let code = ApplicationInfo(
            path: "/Applications/Visual Studio Code.app", name: "Visual Studio Code",
            alternateNames: ["Code"], bundleID: "com.microsoft.VSCode"
        )
        let matcher = matcher(code)
        #expect(matcher.matches("Code", byName: true))
        #expect(matcher.matches("Visual Studio Code", byName: true))
        #expect(matcher.matches("com.example.visualstudiocode.plist", byName: true))
        #expect(matcher.matches("com.microsoft.VSCode.ShipIt", byName: false))
        #expect(!matcher.matches("CodeRunner", byName: true))
    }

    @Test func leavesWhatAnotherApplicationCallsItsOwn() {
        let chrome = ApplicationInfo(path: "/Applications/Google Chrome.app", name: "Google Chrome", bundleID: "com.google.Chrome")
        let canary = ApplicationInfo(path: "/Applications/Google Chrome Canary.app", name: "Google Chrome Canary", bundleID: "com.google.Chrome.canary")

        let ofChrome = matcher(chrome, installed: [canary])
        #expect(ofChrome.matches("com.google.Chrome.plist", byName: false))
        #expect(ofChrome.matches("com.google.Chrome.helper", byName: false))
        #expect(!ofChrome.matches("com.google.Chrome.canary", byName: false))
        #expect(!ofChrome.matches("com.google.Chrome.canary.plist", byName: false))

        // The other way around, the longer identifier is the application's own.
        let ofCanary = matcher(canary, installed: [chrome])
        #expect(ofCanary.matches("com.google.Chrome.canary.plist", byName: false))
        #expect(!ofCanary.matches("com.google.Chrome.plist", byName: false))

        // Once Canary is gone, what it left is nobody's, and goes with Chrome.
        #expect(matcher(chrome).matches("com.google.Chrome.canary.plist", byName: false))
    }

    @Test func leavesAFileNamedLikeAnotherApplication() {
        let notes = ApplicationInfo(path: "/Applications/Notes.app", name: "Notes", bundleID: "dev.example.notes")
        let apple = ApplicationInfo(path: "/System/Applications/Notes.app", name: "Notes", bundleID: "com.apple.Notes")

        // Never Apple's, whether its application is listed or not.
        #expect(!matcher(notes).matches("com.apple.Notes.plist", byName: true))
        #expect(!matcher(notes).matches("com.apple.notes", byName: true))
        #expect(matcher(notes).matches("org.example.notes.plist", byName: true))

        // With two applications of one name, the name says nothing.
        let matcher = matcher(notes, installed: [apple])
        #expect(!matcher.matches("Notes", byName: true))
        #expect(!matcher.matches("org.example.notes.plist", byName: true))
        #expect(matcher.matches("dev.example.notes.plist", byName: true))
    }

    @Test func claimsNothingWithAnIdentifierThatReachesTooFar() {
        // Each says too little to tell one application from all the others
        // under it. Its name, which says nothing either, finds nothing.
        for identifier in ["com", "com.example", "com.apple", "com..app", "com.example.", ".com.example", "com.my app.x"] {
            let app = ApplicationInfo(path: "/Applications/Thing.app", name: "Thing", bundleID: identifier)
            let matcher = matcher(app)
            for name in [
                "com.example.service.plist", "com.example.other.app", "com.apple.accountsd.plist",
                "com.apple.finder.plist", "\(identifier).plist", identifier,
            ] {
                #expect(!matcher.matches(name, byName: false), "\(identifier) took \(name)")
            }
        }
    }

    @Test func takesOnlyExactNamesInApplesNamespace() {
        let pages = ApplicationInfo(path: "/Applications/Pages.app", name: "Pages", bundleID: "com.apple.iWork.Pages")
        let matcher = matcher(pages)
        for name in ["com.apple.iWork.Pages", "com.apple.iWork.Pages.plist", "com.apple.iWork.Pages.savedState",
                     "group.com.apple.iWork.Pages", "AB12CD34EF.com.apple.iWork.Pages"] {
            #expect(matcher.matches(name, byName: false), "\(name)")
        }
        // An application that called itself com.apple.security would
        // otherwise take what macOS keeps under that name.
        for name in ["com.apple.iWork.Pages.Something.plist", "com.apple.iWork.Pages.helper"] {
            #expect(!matcher.matches(name, byName: false), "\(name)")
        }
    }

    @Test func keepsTheFilesASecondCopyShares() {
        let copy = ApplicationInfo(path: "/Users/someone/Applications/Pako.app", name: "Pako", bundleID: "io.github.hinkolas.pako")
        let matcher = matcher(pako, installed: [copy])
        #expect(!matcher.matches("io.github.hinkolas.pako.plist", byName: true))
        #expect(!matcher.matches("Pako", byName: true))
    }

    @Test func takesNoNameThatSaysNothing() {
        for name in ["Helper", "Updater", "Go", "Electron"] {
            let app = ApplicationInfo(path: "/Applications/\(name).app", name: name, bundleID: "dev.example.thing")
            let matcher = matcher(app)
            #expect(!matcher.matches(name, byName: true), "\(name)")
            #expect(!matcher.matches("com.other.\(name.lowercased()).plist", byName: true), "\(name)")
            #expect(matcher.matches("dev.example.thing.plist", byName: true), "\(name)")
        }
    }

    @Test func findsNothingForAnApplicationWithoutAnIdentifierOrAName() {
        let app = ApplicationInfo(path: "/Applications/App.app", name: "App")
        let matcher = matcher(app)
        for name in ["App", "", ".", "com.example.app.plist", "plist"] {
            #expect(!matcher.matches(name, byName: true), "\(name)")
        }
    }
}

@MainActor
@Suite struct ApplicationUninstallerTests {
    /// A home folder of its own, with one application and what it left.
    @MainActor private final class Home {
        let path: String
        let uninstaller: ApplicationUninstaller

        init() throws {
            path = FileManager.default.temporaryDirectory
                .appendingPathComponent("inky-uninstall-\(UUID().uuidString)").path
            uninstaller = ApplicationUninstaller(home: path, coversSystem: false)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(atPath: path)
        }

        @discardableResult
        func addApplication(_ name: String, identifier: String) throws -> ApplicationInfo {
            let bundle = "\(path)/Applications/\(name).app"
            try FileManager.default.createDirectory(atPath: bundle + "/Contents", withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundleShortVersionString": "1.2"]
            #expect(info.write(toFile: bundle + "/Contents/Info.plist", atomically: true))
            return try #require(uninstaller.installedApplications().first { $0.path == bundle })
        }

        func addFile(_ relativePath: String, bytes: Int = 10) throws {
            let file = "\(path)/\(relativePath)"
            try FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            #expect(FileManager.default.createFile(atPath: file, contents: Data(count: bytes)))
        }

        func addFolder(_ relativePath: String) throws {
            try FileManager.default.createDirectory(atPath: "\(path)/\(relativePath)", withIntermediateDirectories: true)
        }
    }

    /// Stands in for the Trash: remembers what it was asked to move.
    @MainActor private final class FakeTrash {
        private(set) var calls: [[String]] = []
        /// Paths that stay where they are.
        var stuck: Set<String> = []

        var trasher: ApplicationUninstaller.Trasher {
            { paths in
                self.calls.append(paths)
                return paths.filter(self.stuck.contains)
            }
        }
    }

    @Test func readsWhatIdentifiesAnApplication() throws {
        let home = try Home()
        let app = try home.addApplication("Pako", identifier: "io.github.hinkolas.pako")
        #expect(app.name == "Pako")
        #expect(app.bundleID == "io.github.hinkolas.pako")
        #expect(app.version == "1.2")
        #expect(home.uninstaller.canUninstall(app))
    }

    @Test func listsTheApplicationAndWhatItLeft() throws {
        let home = try Home()
        let app = try home.addApplication("Pako", identifier: "io.github.hinkolas.pako")
        try home.addApplication("Other", identifier: "dev.example.other")

        try home.addFolder("Library/Application Support/Pako")
        try home.addFile("Library/Application Support/Pako/data.db")
        try home.addFolder("Library/Caches/io.github.hinkolas.pako")
        try home.addFile("Library/Preferences/com.electron.pako.plist")
        try home.addFile("Library/Preferences/io.github.hinkolas.pako.plist")
        try home.addFile("Library/Preferences/ByHost/io.github.hinkolas.pako.ABCD.plist")
        try home.addFolder("Library/Saved Application State/io.github.hinkolas.pako.savedState")
        try home.addFile("Library/LaunchAgents/io.github.hinkolas.pako.agent.plist")

        // Not Pako's.
        try home.addFolder("Library/Application Support/Other")
        try home.addFile("Library/Preferences/dev.example.other.plist")
        try home.addFile("Library/Preferences/com.apple.finder.plist")
        // Named after it, where only an identifier counts.
        try home.addFile("Library/LaunchAgents/Pako.plist")
        // Too deep, and in a folder that is not searched.
        try home.addFile("Library/Application Support/Vendor/Pako/data.db")
        try home.addFile("Library/Mail/io.github.hinkolas.pako.plist")
        try home.addFile("Documents/Pako")

        let items = home.uninstaller.items(for: app, installed: home.uninstaller.installedApplications())
        #expect(items.map { home.uninstaller.abbreviated($0.path) } == [
            "~/Applications/Pako.app",
            "~/Library/Application Support/Pako",
            "~/Library/Caches/io.github.hinkolas.pako",
            "~/Library/Preferences/com.electron.pako.plist",
            "~/Library/Preferences/io.github.hinkolas.pako.plist",
            "~/Library/Saved Application State/io.github.hinkolas.pako.savedState",
            "~/Library/Preferences/ByHost/io.github.hinkolas.pako.ABCD.plist",
            "~/Library/LaunchAgents/io.github.hinkolas.pako.agent.plist",
        ])
        #expect(items.map(\.isApplication) == [true] + Array(repeating: false, count: 7))
    }

    @Test func listsOnlyTheApplicationWhenNothingWasLeft() throws {
        let home = try Home()
        let app = try home.addApplication("Pako", identifier: "io.github.hinkolas.pako")
        let items = home.uninstaller.items(for: app, installed: [app])
        #expect(items == [UninstallItem(path: app.path, isApplication: true)])
    }

    @Test func leavesTheSystemAndInkyAlone() {
        let uninstaller = ApplicationUninstaller()
        #expect(!uninstaller.canUninstall(ApplicationInfo(path: "/System/Applications/Mail.app", name: "Mail")))
        #expect(!uninstaller.canUninstall(ApplicationInfo(path: "/System/Library/CoreServices/Finder.app", name: "Finder")))
        #expect(!uninstaller.canUninstall(ApplicationInfo(path: "/tmp/Somewhere/Thing.app", name: "Thing")))
        #expect(uninstaller.canUninstall(ApplicationInfo(path: "/Applications/Thing.app", name: "Thing")))

        // With a home folder of its own, the applications of the Mac are not its business.
        let confined = ApplicationUninstaller(home: "/tmp/inky-nobody", coversSystem: false)
        #expect(!confined.canUninstall(ApplicationInfo(path: "/Applications/Thing.app", name: "Thing")))
        #expect(confined.canUninstall(ApplicationInfo(path: "/tmp/inky-nobody/Applications/Thing.app", name: "Thing")))
    }

    @Test func measuresFilesAndFolders() throws {
        let home = try Home()
        try home.addFile("Library/Caches/Pako/a", bytes: 5000)
        try home.addFile("Library/Caches/Pako/deep/b", bytes: 9000)

        let file = try #require(ApplicationUninstaller.size(of: home.path + "/Library/Caches/Pako/a"))
        let folder = try #require(ApplicationUninstaller.size(of: home.path + "/Library/Caches/Pako"))
        #expect(file == 5000)
        #expect(folder == 14000)
        #expect(ApplicationUninstaller.size(of: home.path + "/Library/Caches/Nothing") == nil)
    }

    @Test func movesTheApplicationFirst() async throws {
        let home = try Home()
        let app = try home.addApplication("Pako", identifier: "io.github.hinkolas.pako")
        try home.addFolder("Library/Application Support/Pako")
        try home.addFile("Library/Preferences/io.github.hinkolas.pako.plist")
        let items = home.uninstaller.items(for: app, installed: [app])
        let trash = FakeTrash()

        let outcome = try await home.uninstaller.uninstall(items, of: app, trash: trash.trasher)
        #expect(trash.calls == [[app.path], items.dropFirst().map(\.path)])
        #expect(outcome.moved == items)
        #expect(outcome.left.isEmpty)
    }

    @Test func movesOnlyWhatWasChosen() async throws {
        let home = try Home()
        let app = try home.addApplication("Pako", identifier: "io.github.hinkolas.pako")
        try home.addFolder("Library/Application Support/Pako")
        try home.addFile("Library/Preferences/io.github.hinkolas.pako.plist")
        let items = home.uninstaller.items(for: app, installed: [app])
        let trash = FakeTrash()

        // Without the application: its files alone.
        let outcome = try await home.uninstaller.uninstall([items[2]], of: app, trash: trash.trasher)
        #expect(trash.calls == [[items[2].path]])
        #expect(outcome.moved == [items[2]])
    }

    @Test func touchesNothingElseWhenTheApplicationStays() async throws {
        let home = try Home()
        let app = try home.addApplication("Pako", identifier: "io.github.hinkolas.pako")
        try home.addFolder("Library/Application Support/Pako")
        let items = home.uninstaller.items(for: app, installed: [app])
        let trash = FakeTrash()
        trash.stuck = [app.path]

        await #expect(throws: InkyError.self) {
            try await home.uninstaller.uninstall(items, of: app, trash: trash.trasher)
        }
        #expect(trash.calls == [[app.path]])
    }

    @Test func saysWhatCouldNotBeMoved() async throws {
        let home = try Home()
        let app = try home.addApplication("Pako", identifier: "io.github.hinkolas.pako")
        try home.addFolder("Library/Application Support/Pako")
        try home.addFile("Library/Preferences/io.github.hinkolas.pako.plist")
        let items = home.uninstaller.items(for: app, installed: [app])
        let trash = FakeTrash()
        trash.stuck = [items[1].path]

        let outcome = try await home.uninstaller.uninstall(items, of: app, trash: trash.trasher)
        #expect(outcome.moved == [items[0], items[2]])
        #expect(outcome.left == [items[1]])
    }

    @Test func refusesWhatItCouldNotHaveListed() async throws {
        let home = try Home()
        let app = try home.addApplication("Pako", identifier: "io.github.hinkolas.pako")
        let trash = FakeTrash()

        for path in [
            home.path,
            home.path + "/Library",
            home.path + "/Library/Preferences",
            home.path + "/Documents/Pako",
            home.path + "/Library/Application Support/Vendor/Pako",
            home.path + "/Library/Preferences/com.someone.else.plist",
            home.path + "/Library/Caches/Another App",
            "/Applications/Safari.app",
        ] {
            for isApplication in [false, true] {
                let item = UninstallItem(path: path, isApplication: isApplication)
                await #expect(throws: InkyError.self, "\(path)") {
                    try await home.uninstaller.uninstall(
                        [UninstallItem(path: home.path + "/Library/Caches/Pako"), item], of: app, trash: trash.trasher
                    )
                }
            }
        }
        #expect(trash.calls.isEmpty)
    }

    @Test func rechecksSharedFilesBeforeUninstalling() async throws {
        let home = try Home()
        let app = try home.addApplication("Pako", identifier: "io.github.hinkolas.pako")
        try home.addFile("Library/Preferences/io.github.hinkolas.pako.plist")
        let items = home.uninstaller.items(for: app, installed: [app])
        // A second copy appeared after the review was opened.
        try home.addApplication("Pako Copy", identifier: "io.github.hinkolas.pako")
        let trash = FakeTrash()
        await #expect(throws: InkyError.self) {
            try await home.uninstaller.uninstall(items, of: app, trash: trash.trasher)
        }
        #expect(trash.calls.isEmpty)
    }

    @Test func saysWhatHappenedInASentence() {
        let app = UninstallItem(path: "/Applications/Pako.app", isApplication: true)
        let files = (1...3).map { UninstallItem(path: "/Library/Caches/\($0)") }
        func summary(moved: [UninstallItem], left: [UninstallItem] = []) -> String {
            UninstallOutcome(moved: moved, left: left).summary(of: "Pako")
        }

        #expect(summary(moved: [app]) == "Moved “Pako” to the Trash")
        #expect(summary(moved: [app, files[0]]) == "Moved “Pako” and 1 related file to the Trash")
        #expect(summary(moved: [app] + files) == "Moved “Pako” and 3 related files to the Trash")
        #expect(summary(moved: Array(files.prefix(2))) == "Moved 2 files to the Trash")
        #expect(summary(moved: [app, files[0]], left: [files[1]]) == "Moved “Pako” and 1 related file to the Trash. 1 file could not be moved")
        #expect(summary(moved: [], left: files) == "3 files could not be moved to the Trash")
        #expect(summary(moved: []) == "Nothing was moved")
    }

    @Test func writesPathsFinderCanRead() {
        let script = Trash.finderScript(deleting: ["/Applications/Pako.app", "/Library/Caches/A \"quoted\" \\ name"])
        #expect(script == """
        tell application "Finder" to delete {(POSIX file "/Applications/Pako.app" as alias), \
        (POSIX file "/Library/Caches/A \\"quoted\\" \\\\ name" as alias)}
        """)
    }
}
