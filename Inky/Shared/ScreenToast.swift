import AppKit
import SwiftUI

/// The launcher's toast, for when the launcher is gone: a capsule at the
/// bottom of the screen the pointer is on, there for a moment. It takes no
/// clicks and no keys, and is drawn over everything, full screen apps too.
@MainActor
enum ScreenToast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    /// How long it stays.
    private static let duration: Duration = .seconds(2)
    /// From the bottom of the screen, above the Dock if it is there.
    private static let bottomGap: CGFloat = 40
    /// Room around the capsule for its shadow, which is drawn in the window.
    private static let margin = NSEdgeInsets(top: 24, left: 48, bottom: 56, right: 48)
    /// How far it rises as it arrives, where things may travel.
    private static let rise: CGFloat = 8

    /// Shows `message`, with `detail` after it and a dot of `swatch` before
    /// it. One that is showing is replaced.
    static func show(_ message: String, detail: String? = nil, swatch: Color? = nil) {
        let content = ToastContent(message: message, detail: detail, swatch: swatch)
            .padding(EdgeInsets(top: margin.top, leading: margin.left, bottom: margin.bottom, trailing: margin.right))
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize

        let panel = Self.panel ?? makePanel()
        Self.panel = panel
        panel.contentView = host

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: visible.minY + bottomGap - margin.bottom
        )

        let motion = Motion.current
        let wasShowing = panel.isVisible && panel.alphaValue > 0
        if wasShowing || motion.level == .off {
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            let travels = motion.level == .full
            panel.setFrame(NSRect(origin: NSPoint(x: origin.x, y: origin.y - (travels ? rise : 0)), size: size), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = motion.seconds(travels ? 0.2 : 0.14)
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                if travels { panel.animator().setFrameOrigin(origin) }
            }
        }

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private static func hide() {
        guard let panel else { return }
        let motion = Motion.current
        guard motion.level != .off else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = motion.seconds(0.12)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // Shown again while it was fading, it stays.
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The capsule draws its own shadow.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        #if DEBUG
        // A quiet run draws where nobody sees it.
        if DebugLaunch.isQuiet { panel.level = .beneathDesktop }
        #endif
        return panel
    }
}

/// What the toast says: like the launcher's, with a swatch where that has
/// its symbol.
private struct ToastContent: View {
    let message: String
    let detail: String?
    let swatch: Color?

    var body: some View {
        HStack(spacing: 7) {
            if let swatch {
                Circle()
                    .fill(swatch)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                    .frame(width: 16, height: 16)
            }
            Text(message)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .lineLimit(1)
        .padding(.leading, swatch == nil ? 13 : 9)
        .padding(.trailing, 13)
        .frame(height: 32)
        .fixedSize()
        .glassSurface(cornerRadius: nil)
    }
}
