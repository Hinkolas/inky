import AppKit
import SwiftUI

/// Says that Inky was updated, the first time the new version runs.
///
/// Sparkle shows nothing once it has relaunched Inky, and an update that is
/// installed as Inky quits is not seen at all: the menu bar icon only goes
/// and comes back. Inky keeps the version that ran last, and when that
/// changed it says so in a small window, which stays until it is closed.
final class UpdateNotice: NSWindowController, NSWindowDelegate {
    var onClose: () -> Void = {}

    /// The version that ran before this one, if Inky was updated since.
    /// Remembers this one for the next launch.
    static func previousVersion(_ preferences: Preferences) -> String? {
        let version = currentVersion
        let last = preferences.lastVersion
        preferences.lastVersion = version
        // A first launch is welcomed instead.
        guard preferences.hasLaunchedBefore, let last, last != version else { return nil }
        return last
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static func releaseNotes(for version: String) -> URL? {
        URL(string: "https://github.com/Hinkolas/inky/releases/tag/v\(version)")
    }

    init(from previous: String, to version: String) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Inky was updated"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        super.init(window: window)

        let content = UpdatedView(previous: previous, version: version) { [weak self] in
            if let url = Self.releaseNotes(for: version) { NSWorkspace.shared.open(url) }
            self?.close()
        } close: { [weak self] in
            self?.close()
        }
        let host = FirstClickHostingView(rootView: content)
        // The title bar is hidden, and takes no room.
        host.safeAreaRegions = []
        let size = host.fittingSize
        host.frame.size = size
        // Glass, as the launcher is, that stays clear while Inky is not active.
        let background = NSVisualEffectView(frame: host.frame)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(host)
        host.autoresizingMask = [.width, .height]
        window.contentView = background
        window.setContentSize(size)
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(activating: Bool = true) {
        guard let window else { return }
        guard activating else {
            #if DEBUG
            window.level = .beneathDesktop
            #endif
            window.orderFrontRegardless()
            return
        }
        // Inky is not active when it is launched at login or by Sparkle, and
        // activating is only a request: the window is raised regardless,
        // and becomes key once Inky is active.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// Takes the first click, which would otherwise only make Inky active.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct UpdatedView: View {
    let previous: String
    let version: String
    let showNotes: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(.bottom, 10)
            Text("Inky was updated")
                .font(.system(size: 15, weight: .semibold))
            Text("You’re now on \(version).\nBefore, you had \(previous).")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize()
                .padding(.top, 5)
                .padding(.bottom, 18)
            HStack(spacing: 8) {
                Button(action: showNotes) {
                    Text("What’s New").frame(maxWidth: .infinity)
                }
                Button(action: close) {
                    Text("OK").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            // Escape closes it too.
            Button("", action: close)
                .keyboardShortcut(.cancelAction)
                .hidden()
                .frame(width: 0, height: 0)
        }
        .padding(.top, 30)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(width: 280)
    }
}
