import Foundation

/// Installed applications.
@MainActor
public final class ApplicationProvider: Provider {
    public let id = "applications"
    public let info = ProviderInfo(
        title: "Applications",
        summary: "Find and launch the apps installed on this Mac.",
        icon: .symbol("square.grid.2x2.fill", tint: .blue)
    )
    public var onChange: (@MainActor () -> Void)?
    public let refreshInterval: TimeInterval? = 30

    public init() {}

    public func candidates() async -> [ResultItem] {
        let apps = await Task.detached(priority: .userInitiated) {
            ApplicationScanner.scan()
        }.value

        return apps.map { app in
            ResultItem(
                id: "app:\(app.path)",
                title: app.name,
                icon: .file(path: app.path),
                kind: "Application",
                keywords: app.alternateNames,
                actions: [
                    .open(path: app.path),
                    .showInFinder(path: app.path),
                    .copy(app.path, title: "Copy Path", shortcut: KeyShortcut("c", [.command, .shift])),
                ]
            )
        }
    }
}

public struct ApplicationInfo: Sendable, Hashable {
    public var path: String
    /// The name Finder shows, in the user's language.
    public var name: String
    /// Other names worth matching, such as the untranslated one.
    public var alternateNames: [String]
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

    public static func scan() -> [ApplicationInfo] {
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

        for path in searchPaths {
            visit(path, depth: 0)
        }
        for path in extraApplications where fileManager.fileExists(atPath: path) {
            add(path)
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
        if let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = info[key] as? String, value != name, !alternates.contains(value) {
                    alternates.append(value)
                }
            }
        }
        return ApplicationInfo(path: path, name: name, alternateNames: alternates)
    }
}
