import AppKit
import InkyCore
import SwiftUI

enum SettingsPane: Hashable {
    case general
    case about
    case provider(String)
}

/// Which pane the settings window shows. Lives outside the view so the app
/// can open a specific pane.
@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .general
}

final class SettingsWindowController: NSWindowController {
    private let navigation = SettingsNavigation()

    init(context: AppContext) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Inky Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 440)
        window.contentViewController = NSHostingController(
            rootView: SettingsView(context: context, navigation: navigation)
        )
        window.setContentSize(NSSize(width: 780, height: 560))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `pane` is "general", "about" or a provider id.
    func show(pane: String? = nil, activating: Bool = true) {
        switch pane {
        case nil: break
        case "general": navigation.pane = .general
        case "about": navigation.pane = .about
        case let id?: navigation.pane = .provider(id)
        }
        guard activating else {
            #if DEBUG
            window?.level = .beneathDesktop
            #endif
            window?.orderFrontRegardless()
            return
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let context: AppContext
    @Bindable var navigation: SettingsNavigation
    @State private var search = ""

    /// Inky's own commands are always on, so they have no pane.
    private var providers: [any Provider] {
        context.engine.providers.filter { $0.id != "inky" }
    }

    private func matches(_ title: String) -> Bool {
        search.isEmpty || title.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.pane) {
                Section {
                    if matches("General") {
                        SidebarLabel("General", icon: .symbol("gearshape.fill", tint: .gray))
                            .tag(SettingsPane.general)
                    }
                    if matches("About") {
                        SidebarLabel("About", icon: .symbol("info", tint: .indigo))
                            .tag(SettingsPane.about)
                    }
                }
                Section("Extensions") {
                    ForEach(providers.filter { matches($0.info.title) }, id: \.id) { provider in
                        SidebarLabel(provider.info.title, icon: provider.info.icon)
                            .tag(SettingsPane.provider(provider.id))
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search settings")
            .frame(minWidth: 215)
            .navigationSplitViewColumnWidth(min: 215, ideal: 225, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch navigation.pane {
                case .general:
                    GeneralPane(preferences: context.preferences, context: context)
                case .about:
                    AboutPane()
                case .provider(let id):
                    if let provider = providers.first(where: { $0.id == id }) {
                        ProviderPane(provider: provider, context: context)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct SidebarLabel: View {
    let title: String
    let icon: Icon

    init(_ title: String, icon: Icon) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IconView(icon: icon, size: 20)
        }
    }
}

/// The icon, title and description at the top of every pane.
struct PaneHeader: View {
    let icon: Icon
    let title: String
    let summary: String

    var body: some View {
        VStack(spacing: 8) {
            IconView(icon: icon, size: 56)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .textCase(nil)
    }
}
