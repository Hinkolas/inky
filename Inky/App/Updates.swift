import AppKit
import Observation
import Sparkle

/// Which releases Inky updates to.
enum UpdateChannel: String, CaseIterable, Identifiable {
    /// Releases only.
    case stable
    /// Releases and pre-releases: alpha, beta and release candidate versions.
    case beta

    var id: Self { self }

    var title: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        }
    }

    /// The channel of a new installation: a pre-release, whose version has a
    /// suffix such as `-alpha.1`, keeps getting pre-releases.
    static var initial: UpdateChannel {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.contains("-") ? .beta : .stable
    }
}

/// Keeps Inky up to date from its GitHub releases, through Sparkle.
///
/// Sparkle reads the update feed, checks the EdDSA signatures of the feed and
/// of the archive against the public key in Info.plist, and replaces the app.
/// The feed lists every published release; pre-releases are in its `beta`
/// channel, which only builds on the beta channel accept. Sparkle's settings
/// are its own, kept in UserDefaults; this mirrors them for SwiftUI.
@Observable
final class Updates: NSObject {
    /// Nil until started, and in a build that does not update itself.
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var userDriver: UpdateWindows?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Whether a check can be started now: not while one is running.
    private(set) var canCheck = false
    private(set) var lastCheck: Date?

    /// Whether this build updates itself. A development build does not: it
    /// would be replaced by a release. Neither does a build without the
    /// public key that releases are signed with.
    static let isSupported: Bool = {
        #if DEBUG
        return false
        #else
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        return !(key ?? "").isEmpty && !(feed ?? "").isEmpty
        #endif
    }()

    var isAvailable: Bool { updater != nil }

    /// Which releases to update to. Switching back to stable keeps a
    /// pre-release installed until a newer release comes out.
    var channel: UpdateChannel = .stable {
        didSet { UserDefaults.standard.set(channel.rawValue, forKey: Self.channelKey) }
    }

    private static let channelKey = "updateChannel"

    var checksAutomatically = false {
        didSet {
            guard let updater, updater.automaticallyChecksForUpdates != checksAutomatically else { return }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    var installsAutomatically = false {
        didSet {
            guard let updater, updater.automaticallyDownloadsUpdates != installsAutomatically else { return }
            updater.automaticallyDownloadsUpdates = installsAutomatically
        }
    }

    /// Starts checking on Sparkle's schedule, if this build updates itself.
    func start() {
        guard Self.isSupported, updater == nil else { return }
        // Kept from the first launch on, so a pre-release that updates to a
        // release stays on the channel it was downloaded for.
        let stored = UserDefaults.standard.string(forKey: Self.channelKey).flatMap(UpdateChannel.init(rawValue:))
        channel = stored ?? .initial

        let userDriver = UpdateWindows(hostBundle: .main, delegate: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: self)
        do {
            try updater.start()
        } catch {
            NSLog("Inky cannot check for updates: %@", error.localizedDescription)
            return
        }
        self.updater = updater
        self.userDriver = userDriver
        checksAutomatically = updater.automaticallyChecksForUpdates
        installsAutomatically = updater.automaticallyDownloadsUpdates
        canCheck = updater.canCheckForUpdates
        lastCheck = updater.lastUpdateCheckDate

        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            },
            updater.observe(\.lastUpdateCheckDate) { [weak self] updater, _ in
                let value = updater.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheck = value }
            },
        ]
    }

    /// Looks for an update now, and says so when there is none.
    func check() {
        // Inky is not active while its launcher or menu is up. Sparkle asks
        // for that, and its windows are raised regardless.
        NSApp.activate()
        updater?.checkForUpdates()
        // Asked again while still checking, Sparkle does nothing at all, and
        // its window may since have gone behind another app's.
        userDriver?.raise()
    }
}

extension Updates: SPUUpdaterDelegate {
    /// Items without a channel are releases, which every channel gets.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        switch channel {
        case .stable: []
        case .beta: [UpdateChannel.beta.rawValue]
        }
    }
}

extension Updates: SPUStandardUserDriverDelegate {
    /// Inky lives in the menu bar and is rarely active, so an update found in
    /// the background brings Inky forward to show it.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if handleShowingUpdate, !state.userInitiated {
            NSApp.activate()
        }
    }
}

/// Sparkle's windows, brought in front of the app the user is in.
///
/// Inky is rarely the active app: its launcher and menu take keys without
/// making it so. Sparkle asks for Inky to be made active before it shows a
/// window, but that is only a request, which macOS may turn down. A window
/// that went behind another app's then stays there, where only Mission
/// Control finds it, however often the update is asked for. Each window is
/// raised as Settings is, regardless; it becomes key once Inky is active.
/// Sparkle's alerts, that no update was found say, are modal panels, which
/// are in front anyway.
final class UpdateWindows: SPUStandardUserDriver {
    override func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        super.show(request, reply: reply)
        raise()
    }

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        super.showUserInitiatedUpdateCheck(cancellation: cancellation)
        raise()
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        super.showUpdateFound(with: appcastItem, state: state, reply: reply)
        // One found in the background is put behind Inky's own windows
        // while Inky is in use, on purpose.
        if state.userInitiated || !NSApp.isActive { raise() }
    }

    override func showUpdateInFocus() {
        super.showUpdateInFocus()
        raise()
    }

    /// Brings the windows Sparkle shows in front.
    func raise() {
        let sparkle = Bundle(for: SPUStandardUserDriver.self)
        for window in NSApp.windows where window.isVisible {
            guard let controller = window.windowController, Bundle(for: type(of: controller)) == sparkle else { continue }
            window.orderFrontRegardless()
        }
    }
}
