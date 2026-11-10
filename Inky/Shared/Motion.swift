import AppKit
import SwiftUI

/// How the launcher moves. Decided in one place, from the user's setting and
/// the Mac's Reduce Motion, so that every part of the launcher agrees.
///
/// The launcher is opened many times a day, so nothing here is long and
/// nothing makes the user wait: keys are handled while things still move.
nonisolated struct Motion: Equatable, Sendable {
    enum Level: String, Sendable {
        /// Surfaces travel and change shape.
        case full
        /// Nothing travels. What changes fades.
        case reduced
        /// Everything changes at once.
        case off
    }

    var level: Level

    init(level: Level) {
        self.level = level
    }

    init(isEnabled: Bool, reduceMotion: Bool) {
        level = !isEnabled ? .off : reduceMotion ? .reduced : .full
        #if DEBUG
        if let level = Self.debugLevel { self.level = level }
        #endif
    }

    /// For AppKit, which has no environment to read it from.
    @MainActor static var current: Motion {
        Motion(
            isEnabled: Preferences.shared.animations,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    // MARK: - Animations

    /// The bar turning into a command's header and back, and the card following.
    var morph: Animation? {
        animation(.spring(duration: 0.34, bounce: 0.14), reduced: .easeOut(duration: 0.18))
    }

    /// The card following what is typed. Without motion it is simply there.
    var resize: Animation? {
        animation(.smooth(duration: 0.24), reduced: nil)
    }

    /// Small things coming and going: the actions menu, a toast, an argument.
    var quick: Animation? {
        animation(.snappy(duration: 0.2), reduced: .easeOut(duration: 0.14))
    }

    /// Leaving is faster than arriving.
    var exit: Animation? {
        animation(.easeOut(duration: 0.12), reduced: .easeOut(duration: 0.12))
    }

    /// What a screen shows, arriving once its surfaces are on their way.
    var contentIn: Animation? {
        animation(.easeOut(duration: 0.2).delay(0.08), reduced: .easeOut(duration: 0.18))
    }

    /// What a screen showed, out of the way before its surfaces have moved far.
    var contentOut: Animation? {
        animation(.easeOut(duration: 0.09), reduced: .easeOut(duration: 0.18))
    }

    /// For what belongs below the card, once the card has stopped moving.
    var settled: Animation? {
        animation(.easeOut(duration: 0.16).delay(0.2), reduced: .easeOut(duration: 0.16))
    }

    var press: Animation? {
        animation(.easeOut(duration: 0.12), reduced: .easeOut(duration: 0.12))
    }

    /// A field asking for a value.
    var shake: Animation? {
        animation(.linear(duration: 0.38), reduced: nil)
    }

    private func animation(_ full: Animation, reduced: Animation?) -> Animation? {
        let animation: Animation? = switch level {
        case .full: full
        case .reduced: reduced
        case .off: nil
        }
        #if DEBUG
        return animation?.speed(1 / Self.debugSlowdown)
        #else
        return animation
        #endif
    }

    /// The length of something AppKit animates.
    func seconds(_ duration: TimeInterval) -> TimeInterval {
        #if DEBUG
        duration * Self.debugSlowdown
        #else
        duration
        #endif
    }

    // MARK: - Transitions

    /// `moving` where things may travel, a fade where they may not.
    func transition(_ moving: AnyTransition) -> AnyTransition {
        switch level {
        case .full: moving
        case .reduced: .opacity
        case .off: .identity
        }
    }

    /// For something small that arrives with `quick` and leaves faster.
    func popping(_ moving: AnyTransition) -> AnyTransition {
        guard level != .off else { return .identity }
        let transition = transition(moving)
        return .asymmetric(insertion: transition, removal: transition.animation(exit))
    }

    /// For what a screen shows: it comes in from the side the user is heading
    /// to, after what was there has faded.
    func screen(isGoingBack: Bool) -> AnyTransition {
        guard level != .off else { return .identity }
        let arriving = AnyTransition.opacity.combined(with: .offset(x: isGoingBack ? -18 : 18))
        return .asymmetric(
            insertion: transition(arriving).animation(contentIn),
            removal: AnyTransition.opacity.animation(contentOut)
        )
    }

    /// For what belongs below the card: gone before the card grows over
    /// where it was, and back once the card has made room.
    var belowCard: AnyTransition {
        guard level != .off else { return .identity }
        return .asymmetric(insertion: .opacity.animation(settled), removal: .opacity.animation(exit))
    }

    /// A plain fade, or nothing where nothing may animate.
    var fade: AnyTransition {
        level == .off ? .identity : .opacity
    }

    #if DEBUG
    /// Overrides the setting and the system, to look at one level.
    nonisolated(unsafe) static var debugLevel: Level?
    /// Stretches every animation, to look at one frame by frame.
    nonisolated(unsafe) static var debugSlowdown = 1.0
    #endif
}

extension EnvironmentValues {
    /// Set by the launcher for everything in it.
    @Entry var motion = Motion(level: .full)
}

/// Moves a view from side to side and back to rest: "this needs something".
/// Each whole number is at rest; animate from one to the next.
nonisolated struct Shake: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = shakes - shakes.rounded(.down)
        let offset = sin(progress * .pi * 3) * 6 * (1 - progress)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
