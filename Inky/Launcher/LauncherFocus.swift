import AppKit
import SwiftUI

// Where the keyboard is, in the launcher.
//
// The model decides it: every screen has a field that is typed into, and the
// model names it whenever what is showing changes. The launcher's window then
// puts the keyboard there itself, and sees that it stays.
//
// SwiftUI can move focus too, but only to a field that is already on screen,
// and how soon after a field or a window appeared it will do so is not the
// same from one macOS to the next. Asking for it as a screen appeared is what
// used to leave the launcher open with nothing to type into. So SwiftUI only
// reports where the keyboard is, for the fields to draw themselves by, and
// moves it only if the window cannot find the field.

/// Where the launcher's keyboard is, as SwiftUI sees it.
typealias LauncherFocus = FocusState<LauncherModel.FocusTarget?>.Binding

extension View {
    /// Makes a text field the one that is typed into while the launcher's
    /// focus is `target`. Goes on the field itself, before anything that
    /// gives it room around it.
    func launcherFocus(_ focus: LauncherFocus, _ target: LauncherModel.FocusTarget) -> some View {
        focused(focus, equals: target)
            .background { FocusAnchor(target: target) }
    }
}

/// Lies right behind a text field, which tells the window which of the
/// fields SwiftUI made is the one for `target`.
private struct FocusAnchor: NSViewRepresentable {
    let target: LauncherModel.FocusTarget

    func makeNSView(context: Context) -> FocusAnchorView {
        FocusAnchorView(target: target)
    }

    func updateNSView(_ view: FocusAnchorView, context: Context) {
        view.target = target
    }
}

final class FocusAnchorView: NSView {
    var target: LauncherModel.FocusTarget
    /// Higher for one that was made later.
    let serial: Int

    private static var count = 0

    init(target: LauncherModel.FocusTarget) {
        self.target = target
        Self.count += 1
        serial = Self.count
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// It is only there to be found. Clicks are for the field in front of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSView {
    /// The text field for `target` among the views in this one. Nil while
    /// SwiftUI has not made it.
    ///
    /// What lies behind a view is drawn before it, so the field of an anchor
    /// is the first one that comes after it. Where they are does not tell:
    /// while the bar makes room for an argument, the search field still
    /// reaches across it.
    func textField(for target: LauncherModel.FocusTarget) -> NSTextField? {
        // The target's anchors and every field, in the order they are drawn.
        var views: [NSView] = []
        func collect(_ view: NSView) {
            if let anchor = view as? FocusAnchorView {
                if anchor.target == target { views.append(anchor) }
            } else if let field = view as? NSTextField, field.isEditable {
                views.append(field)
            }
            view.subviews.forEach(collect)
        }
        collect(self)

        // A screen that is on its way out can have a field for the same
        // thing. The one that came later is the one that stays.
        let anchors = views.compactMap { $0 as? FocusAnchorView }
        guard let anchor = anchors.max(by: { $0.serial < $1.serial }),
              let index = views.firstIndex(of: anchor),
              let field = views[(index + 1)...].lazy.compactMap({ $0 as? NSTextField }).first
        else { return nil }
        // Laid out, and over its anchor. Should SwiftUI ever order them
        // another way, better none than the wrong one.
        guard field.convert(field.bounds, to: nil).intersects(anchor.convert(anchor.bounds, to: nil)) else { return nil }
        return field
    }
}
