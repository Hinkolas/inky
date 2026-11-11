import AppKit

/// A file or folder that goes when an application is uninstalled.
public struct UninstallItem: Identifiable, Sendable, Hashable {
    public var path: String
    /// The application itself, as opposed to what it left in a Library folder.
    public var isApplication: Bool

    public init(path: String, isApplication: Bool = false) {
        self.path = path
        self.isApplication = isApplication
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// The folder it is in.
    public var folder: String { (path as NSString).deletingLastPathComponent }
}

/// What came of uninstalling.
public struct UninstallOutcome: Sendable {
    /// What is in the Trash now.
    public var moved: [UninstallItem]
    /// What is still where it was.
    public var left: [UninstallItem]

    public init(moved: [UninstallItem], left: [UninstallItem]) {
        self.moved = moved
        self.left = left
    }

    /// What happened, in a sentence, for the application called `name`.
    public func summary(of name: String) -> String {
        func files(_ count: Int, _ kind: String = "") -> String {
            "\(count) \(kind)\(count == 1 ? "file" : "files")"
        }

        let related = moved.count(where: { !$0.isApplication })
        var parts: [String] = []
        if moved.contains(where: \.isApplication) {
            parts.append("Moved “\(name)”\(related > 0 ? " and \(files(related, "related "))" : "") to the Trash")
        } else if related > 0 {
            parts.append("Moved \(files(related)) to the Trash")
        }
        if !left.isEmpty {
            parts.append("\(files(left.count)) could not be moved\(parts.isEmpty ? " to the Trash" : "")")
        }
        return parts.isEmpty ? "Nothing was moved" : parts.joined(separator: ". ")
    }
}

/// Removes an application together with what it left behind: its settings,
/// caches, saved state and the like, which stay when only the application is
/// moved to the Trash.
///
/// Nothing is deleted. Everything goes to the Trash, and the user is shown
/// what was found, and chooses, before any of it does.
public struct ApplicationUninstaller: Sendable {
    /// Written as ~ where a path is shown.
    public let home: String
    /// Where the applications that can be uninstalled are.
    public let applicationFolders: [String]
    private let libraries: [Library]
    private let coversSystem: Bool

    /// A place applications keep files in, and how sure a name has to be.
    private struct Library: Sendable {
        var path: String
        /// A folder in it, and whether a file there may be told by the
        /// application's name. Otherwise only its bundle identifier counts.
        var folders: [(name: String, byName: Bool)]
    }

    /// `home` is the user's folder. With `coversSystem` off, only the
    /// applications and the Library in that folder are looked at, and not the
    /// ones the Mac shares between its users: a folder of made-up
    /// applications can then be uninstalled from without touching real ones.
    public init(home: String = NSHomeDirectory(), coversSystem: Bool = true) {
        self.home = home
        self.coversSystem = coversSystem
        applicationFolders = coversSystem ? ApplicationScanner.searchPaths : [home + "/Applications"]

        var libraries = [Library(path: home + "/Library", folders: [
            ("Application Support", true),
            ("Caches", true),
            ("Logs", true),
            ("Preferences", true),
            ("Saved Application State", true),
            ("HTTPStorages", true),
            ("WebKit", true),
            ("Cookies", true),
            ("Containers", true),
            ("Group Containers", true),
            ("Application Scripts", true),
            ("Preferences/ByHost", false),
            ("LaunchAgents", false),
        ])]
        if coversSystem {
            // Shared by every user and every application on the Mac: a
            // name alone is not enough here.
            libraries.append(Library(path: "/Library", folders: [
                ("Application Support", false),
                ("Caches", false),
                ("Logs", false),
                ("Preferences", false),
                ("LaunchAgents", false),
                ("LaunchDaemons", false),
                ("PrivilegedHelperTools", false),
            ]))
        }
        self.libraries = libraries
    }

    // MARK: - Finding

    /// Every application on the Mac this uninstaller is about, including the
    /// ones it leaves alone: what belongs to them is not another's leftover.
    public func installedApplications() -> [ApplicationInfo] {
        coversSystem ? ApplicationScanner.scan() : ApplicationScanner.scan(applicationFolders)
    }

    /// Whether the application is the user's to remove. What macOS is made
    /// of is not, and neither is Inky while it runs.
    public func canUninstall(_ app: ApplicationInfo) -> Bool {
        guard URL(fileURLWithPath: app.path).standardizedFileURL.path == app.path else { return false }
        guard applicationFolders.contains(where: { app.path.hasPrefix($0 + "/") }) else { return false }
        let resolved = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path
        guard !app.path.hasPrefix("/System/"), !resolved.hasPrefix("/System/") else { return false }
        return resolved != Bundle.main.bundleURL.resolvingSymlinksInPath().path
    }

    /// The application, then what it left in the Library folders.
    ///
    /// `installed` is every application on the Mac, see
    /// `installedApplications`. A file that goes by the identifier of one of
    /// the others is theirs and is left out.
    public func items(for app: ApplicationInfo, installed: [ApplicationInfo]) -> [UninstallItem] {
        guard canUninstall(app) else { return [] }
        let matcher = LeftoverMatcher(app: app, installed: installed)
        let fileManager = FileManager.default
        var items = [UninstallItem(path: app.path, isApplication: true)]

        for library in libraries {
            for folder in library.folders {
                let directory = library.path + "/" + folder.name
                guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
                for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
                    where matcher.matches(name, byName: folder.byName) {
                    items.append(UninstallItem(path: directory + "/" + name))
                }
            }
        }
        return items
    }

    /// The size of the file, or of every file in the folder together, as
    /// Finder lists it. Nil if it cannot be looked into.
    public static func size(of path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileSizeKey, .fileSizeKey]

        func size(_ values: URLResourceValues) -> Int64 {
            Int64(values.totalFileSize ?? values.fileSize ?? 0)
        }

        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard values.isDirectory == true, values.isSymbolicLink != true else { return size(values) }
        // A folder macOS keeps to its owner lists nothing, which is not the
        // same as being empty.
        guard (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil,
              let enumerator = FileManager.default.enumerator(
                  at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
              )
        else { return nil }

        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            // Folders weigh what is in them.
            guard let values = try? file.resourceValues(forKeys: keys), values.isDirectory != true else { continue }
            total += size(values)
        }
        return total
    }

    /// The path with the home folder written as ~.
    public func abbreviated(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Uninstalling

    /// Moves files to the Trash, and returns the ones that are still where
    /// they were.
    public typealias Trasher = @MainActor @Sendable ([String]) async -> [String]

    /// Moves `items` to the Trash, the application first.
    ///
    /// A running application is asked to quit before it goes. If it stays
    /// open, or cannot be moved, nothing else is touched and this throws:
    /// an application is not left behind without its files.
    @MainActor
    public func uninstall(
        _ items: [UninstallItem],
        of app: ApplicationInfo,
        trash: Trasher = Trash.move
    ) async throws -> UninstallOutcome {
        // Only what `items(for:)` could have listed. Whatever else is asked
        // for, by whatever mistake, is not moved.
        let listed = await Task.detached(priority: .userInitiated) {
            Set(self.items(for: app, installed: self.installedApplications()))
        }.value
        for item in items {
            guard listed.contains(item) else {
                throw InkyError("“\(item.name)” is not part of “\(app.name)”")
            }
        }

        var moved: [UninstallItem] = []
        if let bundle = items.first(where: \.isApplication) {
            try await Self.quit(app)
            guard await trash([bundle.path]).isEmpty else {
                throw InkyError("“\(app.name)” could not be moved to the Trash")
            }
            moved.append(bundle)
        }

        let files = items.filter { !$0.isApplication }
        let remaining = files.isEmpty ? [] : Set(await trash(files.map(\.path)))
        moved += files.filter { !remaining.contains($0.path) }
        return UninstallOutcome(moved: moved, left: files.filter { remaining.contains($0.path) })
    }

    /// Asks the application, and the helpers inside it, to quit, and waits
    /// until they have. Nothing is forced: there may be work to save.
    @MainActor
    private static func quit(_ app: ApplicationInfo) async throws {
        let bundle = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path
        let running = NSWorkspace.shared.runningApplications.filter { candidate in
            guard let path = candidate.bundleURL?.resolvingSymlinksInPath().path else { return false }
            return path == bundle || path.hasPrefix(bundle + "/")
        }
        guard !running.isEmpty else { return }

        running.forEach { $0.terminate() }
        for _ in 0..<50 {
            if running.allSatisfy(\.isTerminated) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw InkyError("“\(app.name)” is still open. Quit it and try again.")
    }
}

// MARK: - Trash

public enum Trash {
    /// Moves the files to the Trash, and returns the ones still in place.
    ///
    /// Inky moves what it may. For the rest it asks Finder, which may ask
    /// for an administrator's password: an application installed for every
    /// user belongs to the Mac, not to the person uninstalling it.
    @MainActor
    public static func move(_ paths: [String]) async -> [String] {
        let left = await Task.detached(priority: .userInitiated) {
            paths.filter { path in
                guard exists(path) else { return false }
                return (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) == nil
            }
        }.value
        guard !left.isEmpty else { return [] }

        // Finder says nothing useful when it fails, and nothing at all when
        // the user cancels. What counts is whether the files are gone.
        try? AppleScript.run(finderScript(deleting: left))
        return left.filter(exists)
    }

    /// One delete for all of them, so Finder asks for a password once.
    static func finderScript(deleting paths: [String]) -> String {
        let files = paths.map { path in
            let escaped = path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "(POSIX file \"\(escaped)\" as alias)"
        }
        return "tell application \"Finder\" to delete {\(files.joined(separator: ", "))}"
    }

    /// Whether there is anything at the path, a link that leads nowhere included.
    private nonisolated static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }
}

// MARK: - Matching

/// Tells whether a file in a Library folder was left there by an application.
///
/// Files are named after the application's bundle identifier
/// (`com.example.app.plist`) or after the application (`Example`). The first
/// is certain. The second is taken only for a name that says something, and
/// never for a file that goes by the identifier of another installed
/// application.
struct LeftoverMatcher: Sendable {
    private let identifier: String?
    private let names: Set<String>
    /// The names as the last part of an identifier would spell them.
    private let tails: Set<String>
    private let otherIdentifiers: [String]

    /// Names too common to tell one application's files from another's.
    private static let commonNames: Set<String> = [
        "app", "application", "helper", "agent", "updater", "update", "installer", "uninstaller", "launcher",
        "setup", "daemon", "service", "server", "client", "main", "electron", "java", "python", "test", "demo",
        "desktop", "mac", "macos", "untitled",
    ]

    /// Endings that are not part of the name a file goes by.
    private static let extensions: Set<String> = ["plist", "savedstate", "binarycookies", "log"]

    init(app: ApplicationInfo, installed: [ApplicationInfo]) {
        let others = installed.filter { $0.path != app.path }
        let identifiers = others.compactMap { $0.bundleID?.lowercased() }.filter { !$0.isEmpty }
        otherIdentifiers = identifiers

        // A second copy of the application shares these files, and keeps them.
        let own = app.bundleID?.lowercased()
        identifier = own.flatMap { $0.isEmpty || identifiers.contains($0) ? nil : $0 }

        let taken = Set(others.flatMap { [$0.name] + $0.alternateNames }.map { $0.lowercased() })
        let usable = ([app.name] + app.alternateNames)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count >= 3 && !Self.commonNames.contains($0) && !taken.contains($0) }
        names = Set(usable)
        tails = Set(usable.map { $0.filter { $0.isLetter || $0.isNumber } }.filter { $0.count >= 3 })
    }

    func matches(_ fileName: String, byName: Bool) -> Bool {
        let name = fileName.lowercased()
        let candidates = Self.identifiers(in: name)

        if let identifier, candidates.contains(where: { Self.belongs($0, to: identifier) }) {
            // A longer identifier that fits as well is another application's:
            // what Chrome Canary keeps is not Chrome's.
            return !candidates.contains { candidate in
                otherIdentifiers.contains { $0.count > identifier.count && Self.belongs(candidate, to: $0) }
            }
        }

        guard byName, !names.isEmpty else { return false }
        guard !candidates.contains(where: { candidate in otherIdentifiers.contains { Self.belongs(candidate, to: $0) } }) else {
            return false
        }

        let stem = Self.stem(of: name)
        if names.contains(name) || names.contains(stem) { return true }

        // An identifier that is not the application's own but ends in its
        // name, as a build made during development has: com.electron.example.
        let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts.contains(where: \.isEmpty), let last = parts.last, tails.contains(String(last)) else {
            return false
        }
        // What Apple named stays, unless the application is Apple's.
        return !stem.hasPrefix("com.apple.") || identifier?.hasPrefix("com.apple.") == true
    }

    /// Whether `name` is the identifier, or the identifier with more after it.
    private static func belongs(_ name: String, to identifier: String) -> Bool {
        name == identifier || name.hasPrefix(identifier + ".")
    }

    /// The name, and the name without what containers put in front of an
    /// identifier: `group.` and the ten characters of a developer team.
    private static func identifiers(in name: String) -> [String] {
        var candidates = [name]
        func strip(_ prefix: (String) -> Int?) {
            for candidate in candidates {
                if let length = prefix(candidate), length < candidate.count {
                    candidates.append(String(candidate.dropFirst(length)))
                }
            }
        }
        strip { name in
            let team = name.prefix(10)
            guard name.dropFirst(10).first == ".", team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return 11
        }
        strip { $0.hasPrefix("group.") ? 6 : nil }
        return candidates
    }

    private static func stem(of name: String) -> String {
        let pathExtension = (name as NSString).pathExtension
        return extensions.contains(pathExtension) ? (name as NSString).deletingPathExtension : name
    }
}
