import AppKit

/// Commands that act on the Mac itself.
@MainActor
public final class SystemModule: Module {
    public let id = "system"
    public let info = ModuleInfo(
        title: "System",
        summary: "Lock, sleep, restart and other commands for this Mac.",
        icon: .symbol("gearshape.fill", tint: .gray)
    )
    public var onChange: (@MainActor () -> Void)?

    public init() {}

    private struct Command {
        var id: String
        var title: String
        var symbol: String
        var tint: Tint
        var keywords: [String] = []
        var confirmation: Confirmation?
        var run: @MainActor @Sendable () throws -> Void
    }

    public func candidates() async -> [ResultItem] {
        commands.map { command in
            ResultItem(
                id: "system:\(command.id)",
                title: command.title,
                icon: .symbol(command.symbol, tint: command.tint),
                kind: "System",
                keywords: command.keywords,
                actions: [
                    Action(command.title, symbol: command.symbol, confirmation: command.confirmation) { _ in
                        try command.run()
                    },
                ]
            )
        }
    }

    // Restart, Shut Down and Log Out go through loginwindow, which shows the
    // system's own confirmation dialog and lets apps save their documents.
    private let commands: [Command] = [
        Command(id: "lock", title: "Lock Screen", symbol: "lock.fill", tint: .gray) {
            try lockScreen()
        },
        Command(id: "sleep", title: "Sleep", symbol: "moon.fill", tint: .indigo) {
            try run("/usr/bin/pmset", "sleepnow")
        },
        Command(id: "sleep-displays", title: "Sleep Displays", symbol: "display", tint: .indigo, keywords: ["Turn Off Screen"]) {
            try run("/usr/bin/pmset", "displaysleepnow")
        },
        Command(id: "restart", title: "Restart", symbol: "restart", tint: .orange, keywords: ["Reboot"]) {
            try AppleScript.run("tell application \"loginwindow\" to «event aevtrrst»")
        },
        Command(id: "shut-down", title: "Shut Down", symbol: "power", tint: .red, keywords: ["Power Off"]) {
            try AppleScript.run("tell application \"loginwindow\" to «event aevtrsdn»")
        },
        Command(id: "log-out", title: "Log Out", symbol: "rectangle.portrait.and.arrow.right", tint: .orange, keywords: ["Sign Out"]) {
            try AppleScript.run("tell application \"loginwindow\" to «event aevtrlgo»")
        },
        Command(
            id: "empty-trash", title: "Empty Trash", symbol: "trash.fill", tint: .red,
            confirmation: Confirmation(
                title: "Empty the Trash?",
                message: "Items in the Trash will be permanently deleted.",
                confirmTitle: "Empty Trash"
            )
        ) {
            try AppleScript.run("tell application \"Finder\" to empty trash")
        },
        Command(id: "toggle-appearance", title: "Toggle Dark Mode", symbol: "circle.lefthalf.filled", tint: .gray, keywords: ["Appearance", "Light Mode"]) {
            try AppleScript.run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        },
    ]

    private static func run(_ executable: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
    }

    /// macOS has no public call to lock the screen, so this uses the one the
    /// menu bar's own Lock Screen item is built on.
    private static func lockScreen() throws {
        typealias LockFunction = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else {
            throw InkyError("Locking the screen is not available on this version of macOS")
        }
        _ = unsafeBitCast(symbol, to: LockFunction.self)()
    }
}

public enum AppleScript {
    @MainActor
    public static func run(_ source: String) throws {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // -128 is the user pressing Cancel in a dialog the script showed.
            if error[NSAppleScript.errorNumber] as? Int == -128 { return }
            throw InkyError(error[NSAppleScript.errorMessage] as? String ?? "The command could not be run")
        }
    }
}
