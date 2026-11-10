import AppKit
import Carbon.HIToolbox
import InkyCore
import Observation

/// The launcher's state and behavior: query, results, selection, keyboard.
@Observable
final class LauncherModel {
    /// A view pushed over the search results.
    enum Route {
        case quicklinkEditor(QuicklinkDraft)
    }

    enum FocusTarget: Hashable {
        case search
        case argument(Int)
    }

    @ObservationIgnored let engine: SearchEngine
    @ObservationIgnored let quicklinks: QuicklinkStore
    @ObservationIgnored var dismiss: () -> Void = {}
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var isVisible: () -> Bool = { false }
    @ObservationIgnored private var frontmostPID: pid_t?
    @ObservationIgnored private var deferredSearch: Task<Void, Never>?
    @ObservationIgnored private var toastTimer: Task<Void, Never>?

    private(set) var query = ""
    private(set) var sections: [ResultSection] = []
    private(set) var selectedID: String?
    /// One value per argument of the selected item.
    private(set) var argumentValues: [String] = []
    private(set) var route: Route?
    private(set) var isActionMenuOpen = false
    private(set) var actionMenuIndex = 0
    private(set) var toast: String?

    /// Where keyboard focus should be. Views apply it whenever `focusTick` changes.
    private(set) var focusTarget: FocusTarget = .search
    private(set) var focusTick = 0

    init(engine: SearchEngine, quicklinks: QuicklinkStore) {
        self.engine = engine
        self.quicklinks = quicklinks
    }

    var selectedItem: ResultItem? {
        guard let selectedID else { return nil }
        for section in sections {
            if let item = section.items.first(where: { $0.id == selectedID }) { return item }
        }
        return nil
    }

    /// The first selectable item, which the list scrolls fully to the top for.
    var firstItemID: String? { sections.first?.items.first?.id }

    // MARK: - Lifecycle

    func prepareForShow(frontmostPID: pid_t?) {
        self.frontmostPID = frontmostPID
        engine.reloadStale()
        refresh(resetSelection: true)
    }

    /// Back to a clean slate, so the next show starts instantly and empty.
    func reset() {
        deferredSearch?.cancel()
        query = ""
        route = nil
        isActionMenuOpen = false
        toast = nil
        focusTarget = .search
    }

    // MARK: - Search

    func setQuery(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        refresh(resetSelection: true)
    }

    func refresh(resetSelection: Bool = false) {
        let query = query
        let immediate = engine.results(for: query)
        apply(immediate, resetSelection: resetSelection)

        deferredSearch?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        deferredSearch = Task { [weak self] in
            // Wait for a pause in typing before asking slower sources.
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            let deferred = await engine.deferredResults(for: query)
            guard !Task.isCancelled, query == self.query, !deferred.isEmpty else { return }
            apply(immediate + deferred, resetSelection: false)
        }
    }

    private func apply(_ newSections: [ResultSection], resetSelection: Bool) {
        let previous = selectedID
        sections = newSections

        let stillListed = newSections.contains { $0.items.contains { $0.id == previous } }
        if resetSelection || !stillListed {
            selectedID = firstItemID
        }
        if selectedID != previous || argumentValues.count != (selectedItem?.arguments.count ?? 0) {
            selectionDidChange()
        }
    }

    // MARK: - Selection

    func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        selectionDidChange()
    }

    private func selectionDidChange() {
        argumentValues = Array(repeating: "", count: selectedItem?.arguments.count ?? 0)
        isActionMenuOpen = false
        if focusTarget != .search { focus(.search) }
    }

    private func moveSelection(by offset: Int) {
        let ids = sections.flatMap { $0.items.map(\.id) }
        guard !ids.isEmpty else { return }
        let current = selectedID.flatMap(ids.firstIndex(of:)) ?? 0
        select(ids[(current + offset + ids.count) % ids.count])
    }

    // MARK: - Arguments and focus

    func setArgument(_ index: Int, _ value: String) {
        guard argumentValues.indices.contains(index) else { return }
        argumentValues[index] = value
    }

    func focus(_ target: FocusTarget) {
        focusTarget = target
        focusTick += 1
    }

    /// Called when focus moved without the model asking, such as by a click.
    func focusDidMove(to target: FocusTarget) {
        focusTarget = target
    }

    private func cycleFocus(by offset: Int) {
        let count = selectedItem?.arguments.count ?? 0
        guard count > 0 else { return }
        // Position 0 is the search field, 1...count are the arguments.
        let current = if case .argument(let index) = focusTarget { index + 1 } else { 0 }
        let next = (current + offset + count + 1) % (count + 1)
        focus(next == 0 ? .search : .argument(next - 1))
    }

    // MARK: - Actions

    func runPrimaryAction() {
        runAction(at: 0)
    }

    private func runAction(at index: Int) {
        guard let item = selectedItem, item.actions.indices.contains(index) else { return }
        perform(item.actions[index], on: item)
    }

    func perform(_ action: Action, on item: ResultItem) {
        isActionMenuOpen = false

        if action.usesArguments {
            let missing = item.arguments.indices.first { index in
                item.arguments[index].isRequired
                    && argumentValues[index].trimmingCharacters(in: .whitespaces).isEmpty
            }
            if let missing {
                focus(.argument(missing))
                return
            }
        }

        let query = query
        let context = ActionContext(query: query, arguments: argumentValues, frontmostPID: frontmostPID)
        Task {
            if let confirmation = action.confirmation {
                dismiss()
                guard Alerts.confirm(
                    title: confirmation.title,
                    message: confirmation.message,
                    confirmTitle: confirmation.confirmTitle
                ) else { return }
            }
            do {
                try await action.perform(context)
                engine.recordUse(of: item, query: query)
                if action.behavior == .dismiss { dismiss() }
            } catch {
                report(error)
            }
        }
    }

    /// The keys drawn next to an action: Return for the first, Command-Return
    /// for the second, otherwise the action's own shortcut.
    func shortcutSymbols(for action: Action, at index: Int) -> [String] {
        switch index {
        case 0: ["↵"]
        case 1: ["⌘", "↵"]
        default: action.shortcut?.symbols ?? []
        }
    }

    func toggleActionMenu() {
        guard selectedItem != nil else { return }
        isActionMenuOpen.toggle()
        actionMenuIndex = 0
    }

    private func report(_ error: Error) {
        if isVisible() {
            showToast(error.localizedDescription)
        } else {
            Alerts.show(error: error.localizedDescription)
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTimer?.cancel()
        toastTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Routes

    func editQuicklink(_ quicklink: Quicklink?) {
        isActionMenuOpen = false
        route = .quicklinkEditor(QuicklinkDraft(quicklink))
    }

    func popRoute() {
        route = nil
        focus(.search)
    }

    func saveQuicklink() {
        guard case .quicklinkEditor(let draft) = route else { return }
        guard draft.isValid else {
            showToast("A quicklink needs a name and a link")
            return
        }
        quicklinks.save(draft.quicklink)
        popRoute()
        setQuery("")
        showToast("Quicklink saved")
    }

    // MARK: - Keyboard

    /// Handles a key press before the focused text field sees it.
    /// Returns true if the key was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Self.keyName(event)

        if route != nil {
            switch (key, modifiers) {
            case ("escape", []): popRoute()
            case ("return", .command): saveQuicklink()
            case ("w", .command), ("q", .command): dismiss()
            default: return false
            }
            return true
        }

        if isActionMenuOpen, let item = selectedItem {
            switch (key, modifiers) {
            case ("down", []), ("n", .control):
                actionMenuIndex = (actionMenuIndex + 1) % item.actions.count
                return true
            case ("up", []), ("p", .control):
                actionMenuIndex = (actionMenuIndex - 1 + item.actions.count) % item.actions.count
                return true
            case ("return", []):
                perform(item.actions[actionMenuIndex], on: item)
                return true
            case ("escape", []):
                isActionMenuOpen = false
                return true
            default:
                break
            }
        }

        switch (key, modifiers) {
        case ("down", []), ("n", .control), ("j", .control): moveSelection(by: 1)
        case ("up", []), ("p", .control), ("k", .control): moveSelection(by: -1)
        case ("return", []): runAction(at: 0)
        case ("return", .command): runAction(at: 1)
        case ("tab", []): cycleFocus(by: 1)
        case ("tab", .shift): cycleFocus(by: -1)
        case ("k", .command): toggleActionMenu()
        case (",", .command): openSettings()
        case ("w", .command), ("q", .command): dismiss()
        case ("escape", []):
            if focusTarget != .search {
                focus(.search)
            } else if !query.isEmpty {
                setQuery("")
            } else {
                dismiss()
            }
        default:
            guard let item = selectedItem, let action = item.actions.first(where: { action in
                action.shortcut.map { $0.key == key && $0.modifiers == Self.shortcutModifiers(modifiers) } ?? false
            }) else { return false }
            perform(action, on: item)
        }
        return true
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: "return"
        case kVK_Escape: "escape"
        case kVK_Tab: "tab"
        case kVK_DownArrow: "down"
        case kVK_UpArrow: "up"
        case kVK_Delete: "delete"
        case kVK_Space: "space"
        default: event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }

    private static func shortcutModifiers(_ flags: NSEvent.ModifierFlags) -> KeyShortcut.Modifiers {
        var modifiers: KeyShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}
