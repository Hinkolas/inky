import AppKit
import Carbon.HIToolbox
import InkyCore
import Observation

/// The launcher's state and behavior: query, results, selection, keyboard.
@Observable
final class LauncherModel {
    /// A command's screen, pushed over the search.
    enum Route {
        case quicklinks(QuicklinkBrowser)
        case quicklinkEditor(QuicklinkDraft)
    }

    enum FocusTarget: Hashable {
        case search
        case argument(Int)
    }

    struct MenuSection: Identifiable {
        var title: String
        var actions: [CommandAction]

        var id: String { title }
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
    /// Whether the suggestions are listed although nothing is typed.
    private(set) var isBrowsing = false
    private(set) var sections: [ResultSection] = []
    private(set) var selectedID: String?
    /// One value per argument of the selected item.
    private(set) var argumentValues: [String] = []
    /// The screens pushed over the search, innermost last.
    private(set) var routes: [Route] = []
    /// Whether the last change of screen went back towards the search.
    private(set) var isNavigatingBack = false
    private(set) var isActionMenuOpen = false
    private(set) var actionMenuIndex = 0
    private(set) var toast: String?

    /// Where keyboard focus should be. Views apply it whenever `focusTick` changes.
    private(set) var focusTarget: FocusTarget = .search
    private(set) var focusTick = 0
    /// Counts the times an action was asked for while the focused argument,
    /// which it needs, was still empty.
    private(set) var missingArgumentTick = 0

    init(engine: SearchEngine, quicklinks: QuicklinkStore) {
        self.engine = engine
        self.quicklinks = quicklinks
    }

    var route: Route? { routes.last }

    /// With nothing typed the launcher is just its bar, until the user asks
    /// for the suggestions.
    var showsResults: Bool {
        isBrowsing || !query.trimmingCharacters(in: .whitespaces).isEmpty
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
        isBrowsing = false
        sections = []
        // Without this, reopening onto the same top result would keep the
        // arguments typed last time.
        selectedID = nil
        argumentValues = []
        routes = []
        isNavigatingBack = false
        isActionMenuOpen = false
        toast = nil
        focusTarget = .search
    }

    // MARK: - Search

    func setQuery(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        if newValue.isEmpty { isBrowsing = false }
        refresh(resetSelection: true)
    }

    /// Lists the suggestions without a query.
    func browse() {
        guard !showsResults else { return }
        isBrowsing = true
        refresh(resetSelection: true)
    }

    func refresh(resetSelection: Bool = false) {
        deferredSearch?.cancel()
        guard showsResults else {
            apply([], resetSelection: true)
            return
        }

        let query = query
        let immediate = engine.results(for: query)
        apply(immediate, resetSelection: resetSelection)

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
                // Asking again from inside the empty field is a mistake;
                // the first time, moving there is answer enough.
                if focusTarget == .argument(missing) { missingArgumentTick += 1 }
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

    /// The keys that run an action of a result: Return for the first,
    /// Command-Return for the second, otherwise the action's own shortcut.
    private func shortcut(for action: Action, at index: Int) -> KeyShortcut? {
        switch index {
        case 0: KeyShortcut("return", [])
        case 1: KeyShortcut("return")
        default: action.shortcut
        }
    }

    /// What the actions menu lists: the selected result's actions, then Inky's own.
    var menuSections: [MenuSection] {
        var sections: [MenuSection] = []
        if let item = selectedItem, !item.actions.isEmpty {
            sections.append(MenuSection(title: item.title, actions: item.actions.enumerated().map { index, action in
                CommandAction(title: action.title, symbol: action.symbol, shortcut: shortcut(for: action, at: index)) { [weak self] in
                    self?.perform(action, on: item)
                }
            }))
        }

        var general: [CommandAction] = []
        if !showsResults {
            general.append(CommandAction(title: "Show Suggestions", symbol: "list.bullet", shortcut: KeyShortcut("down", [])) { [weak self] in
                self?.browse()
            })
        }
        general.append(CommandAction(title: "Inky Settings", symbol: "gearshape", shortcut: KeyShortcut(",")) { [weak self] in
            self?.openSettings()
        })
        sections.append(MenuSection(title: "Inky", actions: general))
        return sections
    }

    func toggleActionMenu() {
        isActionMenuOpen.toggle()
        actionMenuIndex = 0
    }

    func runMenuAction(_ action: CommandAction) {
        isActionMenuOpen = false
        action.run()
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

    private func push(_ route: Route) {
        isActionMenuOpen = false
        isNavigatingBack = false
        routes.append(route)
    }

    func popRoute() {
        guard !routes.isEmpty else { return }
        isNavigatingBack = true
        routes.removeLast()
        if routes.isEmpty { focus(.search) }
    }

    func showQuicklinks() {
        push(.quicklinks(QuicklinkBrowser(store: quicklinks)))
    }

    func editQuicklink(_ quicklink: Quicklink?) {
        push(.quicklinkEditor(QuicklinkDraft(quicklink)))
    }

    func saveQuicklink() {
        guard case .quicklinkEditor(let draft) = route else { return }
        guard draft.isValid else {
            showToast("A quicklink needs a name and a link")
            return
        }
        let quicklink = draft.quicklink
        quicklinks.save(quicklink)
        popRoute()
        if case .quicklinks(let browser) = route {
            browser.selectedID = quicklink.id
        } else {
            setQuery("")
        }
        showToast("Quicklink saved")
    }

    /// What the quicklink browser offers for a quicklink. The first runs on Return.
    func actions(for quicklink: Quicklink, in browser: QuicklinkBrowser) -> [CommandAction] {
        var actions = [
            CommandAction(title: "Edit Quicklink", symbol: "pencil", shortcut: KeyShortcut("return", [])) { [weak self] in
                self?.editQuicklink(quicklink)
            },
        ]
        // Arguments are typed in the search bar, which this screen does not have.
        if quicklink.template.arguments.allSatisfy({ !$0.isRequired }) {
            actions.append(CommandAction(title: "Open", symbol: "arrow.up.forward", shortcut: KeyShortcut("return")) { [weak self] in
                guard let self else { return }
                do {
                    try QuicklinkOpener.open(quicklink, context: ActionContext(frontmostPID: frontmostPID))
                    dismiss()
                } catch {
                    report(error)
                }
            })
        }
        actions += [
            CommandAction(title: "Copy Link", symbol: "doc.on.doc", shortcut: KeyShortcut("c", [.command, .shift])) { [weak self] in
                Pasteboard.copy(quicklink.link)
                self?.showToast("Link copied")
            },
            CommandAction(title: "Duplicate", symbol: "plus.square.on.square", shortcut: KeyShortcut("d")) { [weak self] in
                let copy = Quicklink(name: quicklink.name + " Copy", link: quicklink.link, openWith: quicklink.openWith)
                self?.quicklinks.save(copy)
                browser.selectedID = copy.id
            },
            CommandAction(title: "Delete", symbol: "trash", shortcut: KeyShortcut("x", [.control]), isDestructive: true) { [weak self] in
                browser.selectNeighbor(of: quicklink.id)
                self?.quicklinks.delete(quicklink.id)
                self?.showToast("Deleted “\(quicklink.name)”")
            },
        ]
        return actions
    }

    // MARK: - Keyboard

    /// Handles a key press before the focused text field sees it.
    /// Returns true if the key was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = Self.shortcutModifiers(event.modifierFlags)
        let key = Self.keyName(event)

        switch (key, modifiers) {
        case ("w", .command), ("q", .command):
            dismiss()
            return true
        case (",", .command):
            openSettings()
            return true
        default:
            break
        }

        switch route {
        case nil:
            return handleSearchKey(key, modifiers)
        case .quicklinks(let browser):
            return handleKey(key, modifiers, in: browser)
        case .quicklinkEditor:
            switch (key, modifiers) {
            case ("escape", []): popRoute()
            case ("return", .command): saveQuicklink()
            default: return false
            }
            return true
        }
    }

    private func handleSearchKey(_ key: String, _ modifiers: KeyShortcut.Modifiers) -> Bool {
        if isActionMenuOpen {
            let actions = menuSections.flatMap(\.actions)
            switch (key, modifiers) {
            case ("down", []), ("n", .control):
                actionMenuIndex = (actionMenuIndex + 1) % actions.count
                return true
            case ("up", []), ("p", .control):
                actionMenuIndex = (actionMenuIndex - 1 + actions.count) % actions.count
                return true
            case ("return", []):
                runMenuAction(actions[actionMenuIndex])
                return true
            case ("escape", []):
                isActionMenuOpen = false
                return true
            default:
                break
            }
        }

        switch (key, modifiers) {
        case ("down", []), ("n", .control), ("j", .control):
            if showsResults { moveSelection(by: 1) } else { browse() }
        case ("up", []), ("p", .control), ("k", .control):
            moveSelection(by: -1)
        case ("return", []): runAction(at: 0)
        case ("return", .command): runAction(at: 1)
        case ("tab", []): cycleFocus(by: 1)
        case ("tab", .shift): cycleFocus(by: -1)
        case ("k", .command): toggleActionMenu()
        case ("escape", []):
            if focusTarget != .search {
                focus(.search)
            } else if !query.isEmpty {
                setQuery("")
            } else if isBrowsing {
                isBrowsing = false
                refresh()
            } else {
                dismiss()
            }
        default:
            guard let item = selectedItem, let action = item.actions.first(where: { action in
                action.shortcut.map { $0.key == key && $0.modifiers == modifiers } ?? false
            }) else { return false }
            perform(action, on: item)
        }
        return true
    }

    private func handleKey(_ key: String, _ modifiers: KeyShortcut.Modifiers, in browser: QuicklinkBrowser) -> Bool {
        switch (key, modifiers) {
        case ("down", []), ("n", .control), ("j", .control): browser.moveSelection(by: 1)
        case ("up", []), ("p", .control), ("k", .control): browser.moveSelection(by: -1)
        case ("tab", []): browser.cycleFilter(by: 1)
        case ("tab", .shift): browser.cycleFilter(by: -1)
        case ("n", .command): editQuicklink(nil)
        case ("escape", []):
            if browser.query.isEmpty {
                popRoute()
            } else {
                browser.query = ""
            }
        default:
            guard let quicklink = browser.selected,
                  let action = actions(for: quicklink, in: browser).first(where: { action in
                      action.shortcut.map { $0.key == key && $0.modifiers == modifiers } ?? false
                  })
            else { return false }
            action.run()
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
