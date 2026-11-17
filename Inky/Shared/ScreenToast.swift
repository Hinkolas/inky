import AppKit
import SwiftUI

/// A toast for when the launcher is gone: a surface beside the pointer,
/// where the user is looking, there for a moment. It takes no clicks and no
/// keys, and is drawn over everything, full screen apps too.
@MainActor
enum ScreenToast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    /// How long it stays.
    private static let duration: Duration = .seconds(2)
    /// From the tip of the pointer to the toast, clear of the arrow.
    private static let offset = CGSize(width: 18, height: 22)
    /// Room around the surface for its shadow, which is drawn in the window.
    private static let margin = NSEdgeInsets(top: 24, left: 40, bottom: 52, right: 40)
    /// How small it starts, growing out of the pointer, where things may
    /// travel; and how small a toast that replaces one starts.
    private static let arrivingScale = 0.5
    private static let replacingScale = 0.94
    /// How small it gets on its way out.
    private static let leavingScale = 0.9
    private static let scaleKey = "inky.toast.scale"
    /// The pointer, in the window, which the toast grows out of and goes
    /// back towards.
    private static var anchor = CGPoint.zero

    /// Shows `content` on a glass surface beside the pointer: below it and
    /// to the right, unless that is off the screen. One that is showing is
    /// replaced.
    static func show(_ content: some View) {
        let motion = Motion.current
        let host = NSHostingView(rootView: content
            .padding(EdgeInsets(top: margin.top, leading: margin.left, bottom: margin.bottom, trailing: margin.right))
            .environment(\.motion, motion))
        host.wantsLayer = true
        let size = host.fittingSize
        let surface = CGSize(width: size.width - margin.left - margin.right, height: size.height - margin.top - margin.bottom)

        let panel = Self.panel ?? makePanel()
        Self.panel = panel
        let wasShowing = panel.isVisible && panel.alphaValue > 0
        panel.contentView = host

        // Where the surface goes, in screen points, then the window around it.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        var left = pointer.x + offset.width
        if left + surface.width > area.maxX { left = pointer.x - offset.width / 2 - surface.width }
        var top = pointer.y - offset.height
        if top - surface.height < area.minY { top = pointer.y + offset.height / 2 + surface.height }
        left = min(max(left, area.minX + 8), area.maxX - 8 - surface.width)
        top = min(max(top, area.minY + 8 + surface.height), area.maxY - 8)
        let origin = NSPoint(x: (left - margin.left).rounded(), y: (top - surface.height - margin.bottom).rounded())
        anchor = CGPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if motion.level == .off {
            panel.alphaValue = 1
        } else {
            if !wasShowing {
                panel.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = motion.seconds(0.14)
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
            // It grows out of the pointer, and gives a little as it lands.
            if motion.level == .full, let layer = host.layer {
                let animation = CASpringAnimation(perceptualDuration: motion.seconds(0.36), bounce: 0.26)
                animation.keyPath = "transform"
                animation.fromValue = scale(wasShowing ? replacingScale : arrivingScale, of: host)
                animation.toValue = CATransform3DIdentity
                animation.duration = animation.settlingDuration
                layer.add(animation, forKey: scaleKey)
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
        let duration = motion.seconds(0.16)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // Shown again while it was fading, it stays.
                guard panel.alphaValue == 0 else { return }
                panel.orderOut(nil)
                panel.contentView?.layer?.removeAnimation(forKey: scaleKey)
            }
        })
        // And goes back towards the pointer.
        if motion.level == .full, let view = panel.contentView, let layer = view.layer {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.toValue = scale(leavingScale, of: view)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: scaleKey)
        }
    }

    /// The content scaled around the pointer.
    private static func scale(_ scale: CGFloat, of view: NSView) -> CATransform3D {
        guard let layer = view.layer else { return CATransform3DIdentity }
        // A layer's transform is about its anchor point.
        let center = CGPoint(
            x: layer.bounds.minX + layer.bounds.width * layer.anchorPoint.x,
            y: layer.bounds.minY + layer.bounds.height * layer.anchorPoint.y
        )
        let x = anchor.x - center.x
        // Measured from the bottom, whichever way up the view counts.
        let y = anchor.y - center.y
        var transform = CATransform3DMakeTranslation(x, y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -x, -y, 0)
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
        // The surface draws its own shadow.
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
