import Foundation

/// Installed applications.
@MainActor
public final class ApplicationModule: Module {
    public let id = "applications"
    public let info = ModuleInfo(
        title: "Applications",
        summary: "Find and launch the apps installed on this Mac.",
        icon: .symbol("square.grid.2x2.fill", tint: .blue)
    )
    public var onChange: (@MainActor () -> Void)?

    /// Set by the app to show what uninstalling an application would remove.
    public var onUninstall: (@MainActor (ApplicationInfo) -> Void)?
    /// Set by the app to list the applications that can be uninstalled.
    public var onChooseUninstall: (@MainActor () -> Void)?

    public static let uninstallTitle = "Uninstall Application"
    public static let uninstallIcon = Icon.symbol("xmark.app.fill", tint: .red)

    private let uninstaller: ApplicationUninstaller
    /// Where applications are looked for. Nil for where a launcher looks.
    private let folders: [String]?
    /// What was listed last. Nil until the applications were first listed.
    private var listed: [Listed]?
    private var watcher: FolderWatcher?
    private var rescan: Task<Void, Never>?

    /// An application, and whether it can be uninstalled.
    private struct Listed: Equatable, Sendable {
        var app: ApplicationInfo
        var canUninstall: Bool
    }

    /// `folders` and `latency` are for tests: where applications are, and
    /// how long changes to them are gathered before they are looked at.
    public init(
        uninstaller: ApplicationUninstaller = ApplicationUninstaller(),
        folders: [String]? = nil,
        latency: TimeInterval = 2
    ) {
        self.uninstaller = uninstaller
        self.folders = folders
        // Instead of looking again every so often, which took a tenth of a
        // second each time, the folders say when something in them changed.
        let watched = (folders ?? ApplicationScanner.searchPaths) + elsewhere
        watcher = FolderWatcher(watched, latency: latency) { [weak self] in self?.foldersDidChange() }
    }

    /// Where an uninstaller kept to a folder of its own has applications
    /// that nothing else lists. They are found there, to be uninstalled.
    private var elsewhere: [String] {
        uninstaller.applicationFolders.filter { !(folders ?? ApplicationScanner.searchPaths).contains($0) }
    }

    /// The id of an application's result.
    public static func itemID(for path: String) -> String {
        "app:\(path)"
    }

    /// Something changed in a folder of applications, which is mostly an
    /// application that keeps a file of its own there. The applications are
    /// listed again only if they changed.
    private func foldersDidChange() {
        rescan?.cancel()
        rescan = Task {
            let found = await scan()
            // Before they are first listed, they are listed as they are.
            guard !Task.isCancelled, let listed, found != listed else { return }
            onChange?()
        }
    }

    private func scan() async -> [Listed] {
        await Task.detached(priority: .userInitiated) { [uninstaller, folders, elsewhere] in
            let found = ApplicationScanner.scan(folders) + (elsewhere.isEmpty ? [] : ApplicationScanner.scan(elsewhere))
            return found.map { Listed(app: $0, canUninstall: uninstaller.canUninstall($0)) }
        }.value
    }

    public func candidates() async -> [ResultItem] {
        let found = await scan()
        listed = found

        let applications = found.map { listed in
            let app = listed.app
            var actions: [Action] = [
                .open(path: app.path),
                .showInFinder(path: app.path),
                .copy(app.path, title: "Copy Path", shortcut: KeyShortcut("c", [.command, .shift])),
            ]
            if listed.canUninstall {
                // Nothing goes yet: the user is shown what would.
                actions.append(Action(
                    "\(Self.uninstallTitle)…",
                    symbol: "trash",
                    shortcut: KeyShortcut("x", [.control]),
                    behavior: .keepOpen,
                    isDestructive: true
                ) { [weak self] _ in
                    self?.onUninstall?(app)
                })
            }
            return ResultItem(
                id: Self.itemID(for: app.path),
                title: app.name,
                icon: .file(path: app.path),
                kind: "Application",
                keywords: app.alternateNames,
                actions: actions
            )
        }

        let uninstall = ResultItem(
            id: "applications:uninstall",
            title: Self.uninstallTitle,
            icon: Self.uninstallIcon,
            kind: "Command",
            keywords: ["Remove Application", "Delete Application", "Uninstall App"],
            actions: [
                Action("Choose Application", symbol: "xmark.app", behavior: .keepOpen) { [weak self] _ in
                    self?.onChooseUninstall?()
                },
            ]
        )
        return applications + [uninstall]
    }
}

public struct ApplicationInfo: Identifiable, Sendable, Hashable {
    public var path: String
    /// The name Finder shows, in the user's language.
    public var name: String
    /// Other names worth matching, such as the untranslated one.
    public var alternateNames: [String]
    /// What the application calls itself to the system: `com.example.app`.
    public var bundleID: String?
    public var version: String?

    public init(
        path: String,
        name: String,
        alternateNames: [String] = [],
        bundleID: String? = nil,
        version: String? = nil
    ) {
        self.path = path
        self.name = name
        self.alternateNames = alternateNames
        self.bundleID = bundleID
        self.version = version
    }

    public var id: String { path }
}

public enum ApplicationScanner {
    public static let searchPaths: [String] = [
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    /// Apps that live outside the folders above but belong in a launcher.
    private static let extraApplications = [
        "/System/Library/CoreServices/Finder.app",
    ]

    /// The applications in `folders`, or everywhere a launcher looks if
    /// none are given.
    public static func scan(_ folders: [String]? = nil) -> [ApplicationInfo] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var apps: [ApplicationInfo] = []

        func add(_ path: String) {
            // /Applications/Safari.app is a link into a system volume; keep the
            // path the user knows but only list the app once.
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seen.insert(resolved).inserted else { return }
            apps.append(describe(path, fileManager))
        }

        func visit(_ directory: String, depth: Int) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = directory + "/" + name
                let pathExtension = (name as NSString).pathExtension
                if pathExtension == "app" {
                    add(path)
                } else if pathExtension.isEmpty, depth < 2 {
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                        visit(path, depth: depth + 1)
                    }
                }
            }
        }

        for path in folders ?? searchPaths {
            visit(path, depth: 0)
        }
        if folders == nil {
            for path in extraApplications where fileManager.fileExists(atPath: path) {
                add(path)
            }
        }
        return apps
    }

    private static func describe(_ path: String, _ fileManager: FileManager) -> ApplicationInfo {
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var name = fileManager.displayName(atPath: path)
        if name.hasSuffix(".app") {
            name = (name as NSString).deletingPathExtension
        }

        var alternates: [String] = []
        if fileName != name { alternates.append(fileName) }
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        if let info {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = info[key] as? String, value != name, !alternates.contains(value) {
                    alternates.append(value)
                }
            }
        }
        return ApplicationInfo(
            path: path,
            name: name,
            alternateNames: alternates,
            bundleID: info?["CFBundleIdentifier"] as? String,
            version: info?["CFBundleShortVersionString"] as? String
        )
    }
}
