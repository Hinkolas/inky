import AppKit
import InkyCore
import SwiftUI

// A command is anything a module lists: an application, a quicklink, a
// system command. Each can be switched off, and given a hotkey that runs it
// from anywhere. The rows here are where that is done: in the pane of the
// module a command comes from, and in one pane that lists them all.

// MARK: - Row

/// One command: its icon and name, its hotkey, and a box to switch it off.
struct CommandRow<Accessory: View>: View {
    let id: String
    let title: String
    var subtitle: String?
    let icon: Icon
    let context: AppContext
    /// Whether the module the command comes from is on. A command of a
    /// module that is off cannot be changed until the module is back.
    var isModuleEnabled = true
    /// What else can be done with the command, between the hotkey and the box.
    @ViewBuilder var accessory: Accessory

    /// Why the keys pressed last could not become the hotkey.
    @State private var refusal: String?

    var body: some View {
        let preferences = context.preferences
        let store = context.engine.commandStore
        let isOn = store.isEnabled(id)
        let isActive = isOn && isModuleEnabled

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    IconView(icon: icon, size: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 12)
                    Group {
                        HotkeyRecorder(
                            combo: Binding(
                                get: { store.hotkey(for: id) },
                                set: {
                                    refusal = nil
                                    store.setHotkey($0, for: id)
                                }
                            ),
                            style: .inline,
                            refusal: { combo in
                                refusal = reason(against: combo)
                                return refusal
                            }
                        ) { isRecording in
                            if isRecording { refusal = nil }
                            preferences.isRecordingHotkey = isRecording
                        }
                        accessory
                    }
                    .disabled(!isActive)
                }
                // What is off is still there, to be switched on again: the
                // box beside it stays as it is.
                .opacity(isActive ? 1 : 0.45)

                if let problem = refusal ?? unavailability {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.leading, 30)
                }
            }

            Toggle("Enable \(title)", isOn: Binding(
                get: { isOn },
                set: { store.setEnabled(id, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isModuleEnabled)
            .help(isOn ? "Switch \(title) off" : "Switch \(title) on")
        }
    }

    /// Why the command's hotkey does nothing, if it does nothing.
    private var unavailability: String? {
        let preferences = context.preferences
        guard preferences.unavailableHotkeys.contains(id),
              let combo = context.engine.commandStore.hotkey(for: id)
        else { return nil }
        return reason(against: combo) ?? "macOS did not accept this hotkey. Choose a different one."
    }

    /// Why `combo` cannot be the command's hotkey, or nil if it can.
    private func reason(against combo: KeyCombo) -> String? {
        if combo == context.preferences.hotkey {
            return "This hotkey already opens Inky. Choose a different one."
        }
        if let other = context.engine.commandStore.command(with: combo), other != id {
            let name = context.engine.item(withID: other)?.title ?? "another command"
            return "This is already the hotkey of \(name)."
        }
        return nil
    }
}

extension CommandRow where Accessory == EmptyView {
    init(item: ResultItem, context: AppContext, isModuleEnabled: Bool = true) {
        self.init(
            id: item.id,
            title: item.title,
            icon: item.icon,
            context: context,
            isModuleEnabled: isModuleEnabled
        ) {}
    }
}

// MARK: - In a module's pane

/// The commands of one module, for its pane: the commands themselves first,
/// then what the module finds, such as the applications.
struct ModuleCommands: View {
    let module: any Module
    let context: AppContext

    /// What the things a module lists are called together. Everything else
    /// is a command.
    private static let groupTitles = ["Application": "Applications", "Quicklink": "Quicklinks"]
    static let commandsTitle = "Commands"

    /// The commands under the title of their group, `Commands` first.
    static func groups(of items: [ResultItem]) -> [(title: String, items: [ResultItem])] {
        let grouped = Dictionary(grouping: items) { groupTitles[$0.kind] ?? commandsTitle }
        return grouped
            .sorted { first, second in
                if first.key == commandsTitle || second.key == commandsTitle { return first.key == commandsTitle }
                return first.key < second.key
            }
            .map { (title: $0.key, items: $0.value) }
    }

    var body: some View {
        let isModuleEnabled = context.preferences.isEnabled(module.id)
        let groups = Self.groups(of: context.engine.commands(in: module.id))

        ForEach(groups, id: \.title) { group in
            Section {
                ForEach(group.items) { item in
                    CommandRow(item: item, context: context, isModuleEnabled: isModuleEnabled)
                }
            } header: {
                Text(group.title)
            } footer: {
                if group.title == groups.last?.title {
                    Text("A command that is switched off is not found or suggested. A hotkey runs a command from anywhere.")
                }
            }
        }
    }
}

// MARK: - All commands

/// Every command of every module in one list, to switch them on and off and
/// give them hotkeys without going from pane to pane.
struct CommandsPane: View {
    static let title = "Commands"
    static let icon = Icon.symbol("command", tint: .pink)

    let context: AppContext
    @Bindable var navigation: SettingsNavigation
    /// The modules whose commands are folded away or, for a module with
    /// many, shown.
    @State private var toggled: Set<String> = []

    /// A module with more commands than this starts folded away.
    private static let foldedAbove = 12

    private struct Group: Identifiable {
        let module: any Module
        /// All of the module's commands.
        let count: Int
        /// The ones to list: all of them, or those the search found.
        let items: [ResultItem]

        var id: String { module.id }
    }

    private var search: String {
        navigation.commandSearch.trimmingCharacters(in: .whitespaces)
    }

    private var groups: [Group] {
        let search = search
        return context.engine.modules.compactMap { module in
            let items = context.engine.commands(in: module.id)
            guard !search.isEmpty else {
                return Group(module: module, count: items.count, items: items)
            }
            // The name of a module finds everything in it.
            if module.info.title.localizedCaseInsensitiveContains(search) {
                return Group(module: module, count: items.count, items: items)
            }
            let found = items.filter { $0.title.localizedCaseInsensitiveContains(search) }
            return found.isEmpty ? nil : Group(module: module, count: items.count, items: found)
        }
    }

    private func isExpanded(_ group: Group) -> Bool {
        // What was searched for is there to be seen.
        if !search.isEmpty { return true }
        return (group.count <= Self.foldedAbove) != toggled.contains(group.id)
    }

    var body: some View {
        let groups = groups
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search commands", text: $navigation.commandSearch, prompt: Text("Search commands"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                    if !navigation.commandSearch.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { navigation.commandSearch = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Show all commands")
                    }
                }
            } header: {
                PaneHeader(
                    icon: Self.icon,
                    title: Self.title,
                    summary: "Switch commands on or off, and run them from anywhere with a hotkey."
                )
            } footer: {
                if groups.isEmpty {
                    Text("No command is called “\(search)”.")
                }
            }

            ForEach(groups) { group in
                let isExpanded = isExpanded(group)
                // Inky's own commands come with no switch for all of them.
                let hasSwitch = group.module.id != "inky"
                let isModuleEnabled = !hasSwitch || context.preferences.isEnabled(group.id)
                Section {
                    ModuleRow(
                        module: group.module,
                        count: group.count,
                        isExpanded: group.count == 0 ? nil : isExpanded,
                        isEnabled: hasSwitch ? Binding(
                            get: { context.preferences.isEnabled(group.id) },
                            set: { context.preferences.setEnabled(group.id, $0) }
                        ) : nil
                    ) {
                        if toggled.contains(group.id) {
                            toggled.remove(group.id)
                        } else {
                            toggled.insert(group.id)
                        }
                    }
                    if isExpanded {
                        ForEach(group.items) { item in
                            CommandRow(item: item, context: context, isModuleEnabled: isModuleEnabled)
                        }
                    }
                }
            }
        }
    }
}

/// The module a group of commands comes from, with a box to switch all of
/// it off. A click shows or folds away its commands.
private struct ModuleRow: View {
    let module: any Module
    let count: Int
    /// Nil for a module without commands, which has nothing to show.
    let isExpanded: Bool?
    /// Nil for a module that is always on.
    let isEnabled: Binding<Bool>?
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    IconView(icon: module.info.icon, size: 20)
                    Text(module.info.title)
                        .fontWeight(.medium)
                    if let isExpanded {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    Spacer(minLength: 12)
                    if count > 0 {
                        Text(count == 1 ? "1 command" : "\(count) commands")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A module without commands has nothing to show or fold away.
            .allowsHitTesting(isExpanded != nil)
            .opacity(isEnabled?.wrappedValue == false ? 0.45 : 1)
            .accessibilityLabel(module.info.title)
            .accessibilityHint(isExpanded == true ? "Hides its commands" : "Shows its commands")

            if let isEnabled {
                Toggle("Enable \(module.info.title)", isOn: isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(isEnabled.wrappedValue ? "Switch \(module.info.title) off" : "Switch \(module.info.title) on")
            } else {
                // Keeps the count where it is in the other rows.
                Color.clear.frame(width: 16, height: 16)
            }
        }
    }
}
