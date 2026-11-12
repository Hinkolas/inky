import AppKit
import Carbon.HIToolbox
import InkyCore
import Observation
import SwiftUI

/// The launcher's state and behavior: query, results, selection, keyboard.
@Observable
final class LauncherModel {
    /// A command's screen, pushed over the search.
    enum Route {
        case quicklinks(QuicklinkBrowser)
        case quicklinkEditor(QuicklinkDraft)
        case uninstallBrowser(UninstallBrowser)
        case uninstall(UninstallReview)
        case clipboard(ClipboardBrowser)
    }

    /// A field that can be typed into.
    enum FocusTarget: Hashable {
        case search
        case argument(Int)
        /// The field in a command's header that narrows down what it lists.
        case filter
        case quicklinkName
        case quicklinkLink
        /// The name of the entry of the clipboard history that is being renamed.
        case clipName
    }

    struct MenuSection: Identifiable {
        var title: String
        var actions: [CommandAction]

        var id: String { title }
    }

    @ObservationIgnored let engine: SearchEngine
    @ObservationIgnored let quicklinks: QuicklinkStore
    @ObservationIgnored let uninstaller: ApplicationUninstaller
    @ObservationIgnored let clipboard: ClipboardHistory
    /// What was typed into the search before, for ↑ to bring back.
    @ObservationIgnored let history: InputHistory
    /// Called after an application was uninstalled.
    @ObservationIgnored var applicationsDidChange: () -> Void = {}
    @ObservationIgnored var dismiss: () -> Void = {}
    /// Puts the launcher away as it is, to be opened again where it was left.
    @ObservationIgnored var setAside: () -> Void = {}
    /// Closes the launcher, and runs what it is given once the launcher is
    /// gone and the keyboard is back with the application behind it.
    @ObservationIgnored var dismissThen: (@escaping () -> Void) -> Void = { $0() }
    /// Whether Return pastes an entry of the clipboard history. Otherwise it copies.
    @ObservationIgnored var pastesOnReturn: () -> Bool = { true }
    /// Whether pasting may press keys in other applications. Off for runs
    /// that are not to be noticed.
    @ObservationIgnored var pressesKeys = true
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var configureFallbacks: () -> Void = {}
    /// Shows a command in the settings, where it gets a hotkey.
    @ObservationIgnored var configureCommand: (ResultItem) -> Void = { _ in }
    @ObservationIgnored var isVisible: () -> Bool = { false }
    /// Called when the keyboard is wanted somewhere. The launcher's window
    /// puts it there.
    @ObservationIgnored var focusDidChange: () -> Void = {}
    /// True for a moment after the keyboard was asked somewhere, while the
    /// window sees it get there. Until then, where it is says nothing about
    /// where the user wants it.
    @ObservationIgnored var isFocusSettling = false
    @ObservationIgnored private var frontmostPID: pid_t?
    @ObservationIgnored private var deferredSearch: Task<Void, Never>?
    @ObservationIgnored private var toastTimer: Task<Void, Never>?
    /// The command whose screen lies right on the search, if one put it there.
    @ObservationIgnored private var rootCommand: String?
    /// Whether the next screen is simply there instead of arriving, as when
    /// the launcher opens straight to it.
    @ObservationIgnored private var arrivesInstantly = false
    /// Where in the history the search is, while the arrow keys go through it.
    @ObservationIgnored private var recallIndex: Int?
    /// A result of the slower sources that is to be selected once they
    /// have found it, with what goes into its arguments.
    @ObservationIgnored private var awaitedSelection: (id: String, arguments: [String])?
    /// What the slower sources found, and for which search.
    @ObservationIgnored private var deferred: (query: String, sections: [ResultSection])?
    /// Whether the search was put there by a command's hotkey, not typed.
    @ObservationIgnored private var isQueryPlaced = false

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

    /// The field the keyboard should be in. Nil on a screen that has
    /// nothing to type into.
    private(set) var focusTarget: FocusTarget? = .search
    /// Goes up when SwiftUI is to move the keyboard there itself, because
    /// the window could not find the field.
    private(set) var focusFallbackTick = 0
    /// Counts the times an action was asked for while the focused argument,
    /// which it needs, was still empty.
    private(set) var missingArgumentTick = 0

    init(
        engine: SearchEngine,
        quicklinks: QuicklinkStore,
        uninstaller: ApplicationUninstaller,
        clipboard: ClipboardHistory,
        history: InputHistory
    ) {
        self.engine = engine
        self.quicklinks = quicklinks
        self.uninstaller = uninstaller
        self.clipboard = clipboard
        self.history = history
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

    /// The first selectable item.
    var firstItemID: String? { sections.first?.items.first?.id }
    /// Every selectable item, in the order the arrow keys go through them.
    var itemIDs: [String] { sections.flatMap { $0.items.map(\.id) } }

    // MARK: - Lifecycle

    /// `resuming` is for a launcher that was put away as it was: what it
    /// shows is brought up to date, and what is selected stays selected.
    func prepareForShow(frontmostPID: pid_t?, resuming: Bool = false) {
        self.frontmostPID = frontmostPID
        engine.reloadStale()
        refresh(resetSelection: !resuming)
        guard resuming else { return }
        // What a command lists may have changed while it was away.
        switch route {
        case .clipboard(let browser): browser.reload()
        case .uninstallBrowser(let browser): browser.reload()
        case nil, .quicklinks, .quicklinkEditor, .uninstall: break
        }
    }

    /// Whether the launcher shows anything worth opening it with again.
    var hasSomethingToResume: Bool {
        route != nil || showsResults
    }

    /// Put away to be opened again as it is. Only what was passing goes.
    func suspend() {
        deferredSearch?.cancel()
        isActionMenuOpen = false
        isNavigatingBack = false
        toastTimer?.cancel()
        toast = nil
    }

    /// Back to a clean slate, so the next show starts instantly and empty.
    /// What was in the search is remembered.
    func reset() {
        rememberInput()
        recallIndex = nil
        awaitedSelection = nil
        deferred = nil
        isQueryPlaced = false
        deferredSearch?.cancel()
        query = ""
        isBrowsing = false
        sections = []
        // Without this, reopening onto the same top result would keep the
        // arguments typed last time.
        selectedID = nil
        argumentValues = []
        routes = []
        rootCommand = nil
        isNavigatingBack = false
        isActionMenuOpen = false
        toast = nil
        focusTarget = .search
    }

    // MARK: - Search

    func setQuery(_ newValue: String) {
        guard newValue != query else { return }
        // Typed, it is a search like any other.
        recallIndex = nil
        awaitedSelection = nil
        isQueryPlaced = false
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
            deferred = nil
            apply([], resetSelection: true)
            return
        }

        let query = query
        let immediate = engine.results(for: query)
        // What the slower sources found for this very search stays while
        // they are asked again, and with it the selection, if it is theirs.
        let known = deferred?.query == query ? deferred?.sections ?? [] : []
        if known.isEmpty { deferred = nil }
        // Last, below whatever was found or is still to come.
        let fallbacks = engine.fallbacks(for: query).map { [$0] } ?? []
        // Results can turn up for what is already typed, as when the exchange
        // rates arrive. A fallback that was selected only because there was
        // nothing else gives way to them, as it does to slower sources below.
        let hadOnlyFallbacks = !immediate.isEmpty && sections.map(\.id) == fallbacks.map(\.id)
            && selectedID == fallbacks.first?.items.first?.id
        apply(immediate + known + fallbacks, resetSelection: resetSelection || hadOnlyFallbacks)

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        deferredSearch = Task { [weak self] in
            // Wait for a pause in typing before asking slower sources.
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            let found = await engine.deferredResults(for: query)
            guard !Task.isCancelled, query == self.query else { return }
            defer { selectAwaited() }
            guard !found.isEmpty || !known.isEmpty else { return }
            deferred = found.isEmpty ? nil : (query, found)
            // A fallback that was selected only because nothing had been
            // found yet gives way to what has been found now.
            let wasOnlyChoice = immediate.isEmpty && known.isEmpty && selectedID == fallbacks.first?.items.first?.id
            apply(immediate + found + fallbacks, resetSelection: wasOnlyChoice)
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

    /// Selects a result the user chose, as by clicking it.
    func select(_ id: String) {
        recallIndex = nil
        choose(id)
    }

    private func choose(_ id: String) {
        awaitedSelection = nil
        guard id != selectedID else { return }
        selectedID = id
        selectionDidChange()
    }

    private func selectionDidChange() {
        argumentValues = Array(repeating: "", count: selectedItem?.arguments.count ?? 0)
        isActionMenuOpen = false
        // The arguments went with the result they were for. Results also
        // change behind a command's screen, which has the keyboard then.
        if route == nil, focusTarget != .search { focus(.search) }
    }

    private func moveSelection(by offset: Int) {
        let ids = itemIDs
        guard !ids.isEmpty else { return }
        let current = selectedID.flatMap(ids.firstIndex(of:)) ?? 0
        choose(ids[(current + offset + ids.count) % ids.count])
    }

    // MARK: - Arguments and focus

    func setArgument(_ index: Int, _ value: String) {
        guard argumentValues.indices.contains(index), argumentValues[index] != value else { return }
        recallIndex = nil
        argumentValues[index] = value
    }

    func focus(_ target: FocusTarget?) {
        focusTarget = target
        focusDidChange()
    }

    /// The field a screen is typed into, unless the user moved elsewhere.
    private var defaultFocus: FocusTarget? {
        switch route {
        case nil: .search
        case .quicklinks, .uninstallBrowser: .filter
        case .quicklinkEditor(let draft): draft.isNew ? .quicklinkName : .quicklinkLink
        // It lists what goes with an application. There is nothing to type.
        case .uninstall: nil
        case .clipboard(let browser): browser.renaming == nil ? .filter : .clipName
        }
    }

    /// Puts the keyboard where the screen that is showing wants it: when
    /// the launcher opens, the screen changes, or a field comes or goes.
    func focusDefault() {
        focus(defaultFocus)
    }

    /// Called when focus moved without the model asking, such as by a click.
    func focusDidMove(to target: FocusTarget) {
        guard !isFocusSettling else { return }
        focusTarget = target
    }

    /// Has SwiftUI move the keyboard, for a field the window did not find.
    func focusBySwiftUI() {
        focusFallbackTick += 1
    }

    private func cycleFocus(by offset: Int) {
        let count = selectedItem?.arguments.count ?? 0
        guard count > 0 else { return }
        // Whoever goes into what was brought back means to work with it.
        recallIndex = nil
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

        run(action, on: item, context: ActionContext(query: query, arguments: argumentValues, frontmostPID: frontmostPID))
    }

    /// `replacingScreens` lets a screen the action shows take the place of
    /// the ones that are showing, and `instantly` has it simply be there.
    private func run(
        _ action: Action,
        on item: ResultItem,
        context: ActionContext,
        replacingScreens: Bool = false,
        instantly: Bool = false
    ) {
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
                let depth = routes.count
                arrivesInstantly = instantly
                defer { arrivesInstantly = false }
                try await action.perform(context)
                if routes.count > depth {
                    if replacingScreens, depth > 0 { routes.removeFirst(depth) }
                    if routes.count == 1 { rootCommand = item.id }
                }
                // Deleting something is not a sign it should rank higher,
                // or something to do again.
                if !action.isDestructive {
                    engine.recordUse(of: item, query: context.query)
                    history.record(query: context.query, arguments: context.arguments, itemID: item.id, submitted: true)
                    recallIndex = nil
                }
                if action.behavior == .dismiss { dismiss() }
            } catch {
                report(error)
            }
        }
    }

    // MARK: - History

    // What was typed into the search is kept when it goes: run, cleared, or
    // closed for good. ↑ in the empty search brings it back, newest first,
    // and from there the arrow keys go through the history until something
    // is typed.

    /// Keeps what is in the search for ↑ to bring back, before it goes.
    func rememberInput() {
        // Brought back and left as it was, it is in the history already,
        // and no more recent for having been looked at.
        guard recallIndex == nil else { return }
        // A command's hotkey put its name there. Only what was typed into
        // its arguments is the user's.
        let hasArguments = argumentValues.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !isQueryPlaced || hasArguments else { return }
        history.record(query: query, arguments: argumentValues, itemID: selectedID)
    }

    /// Empties the search, as Escape does there.
    func clearQuery() {
        rememberInput()
        setQuery("")
    }

    /// Whether ↑ goes back through what was typed before. With nothing
    /// typed there is nothing else for it to do.
    private var recalls: Bool {
        recallIndex != nil || (query.isEmpty && !isBrowsing && !history.entries.isEmpty)
    }

    /// Goes through the history: towards older entries, or back (negative).
    private func recall(by offset: Int) {
        let index = (recallIndex ?? -1) + offset
        guard index >= 0 else {
            // Past the newest is the empty search it all started from.
            setQuery("")
            return
        }
        // At the oldest, there it stays.
        guard history.entries.indices.contains(index) else { return }
        let entry = history.entries[index]
        recallIndex = index
        awaitedSelection = nil
        isQueryPlaced = false
        isBrowsing = false
        query = entry.query
        refresh(resetSelection: true)
        guard let id = entry.itemID else { return }
        if itemIDs.contains(id) {
            choose(id)
            fill(entry.arguments)
        } else {
            // The slower sources may still find it.
            awaitedSelection = (id, entry.arguments)
        }
    }

    /// Selects the result that was waited for, if it has turned up.
    private func selectAwaited() {
        guard let awaited = awaitedSelection else { return }
        awaitedSelection = nil
        guard itemIDs.contains(awaited.id) else { return }
        choose(awaited.id)
        fill(awaited.arguments)
    }

    /// Puts back what was typed into the arguments of the selected result.
    private func fill(_ arguments: [String]) {
        guard !arguments.isEmpty, arguments.count == argumentValues.count else { return }
        argumentValues = arguments
    }

    #if DEBUG
    /// Where in the history the search is, for the state a run prints.
    var debugRecallIndex: Int? { recallIndex }
    #endif

    // MARK: - Hotkeys of commands

    /// Whether a command's hotkey has to show the launcher: for the screen
    /// the command opens in it, or for the arguments it asks for.
    func opensLauncher(_ item: ResultItem) -> Bool {
        guard let action = item.actions.first else { return false }
        return action.behavior == .keepOpen || asksForArguments(item, action)
    }

    private func asksForArguments(_ item: ResultItem, _ action: Action) -> Bool {
        action.usesArguments && item.arguments.contains(where: \.isRequired)
    }

    /// Whether the launcher shows what the command's hotkey shows, so that
    /// the hotkey can put it away again.
    func isShowing(_ item: ResultItem) -> Bool {
        if route != nil { return rootCommand == item.id }
        return selectedID == item.id && query == item.title
    }

    /// Runs a command that needs nothing of the launcher, as its hotkey does.
    /// `frontmostPID` is the application the user is in.
    func run(_ item: ResultItem, frontmostPID: pid_t?) {
        guard let action = item.actions.first else { return }
        let context = ActionContext(
            arguments: Array(repeating: "", count: item.arguments.count),
            frontmostPID: frontmostPID
        )
        run(action, on: item, context: context)
    }

    /// Shows what a command's hotkey shows, in a launcher that is open: the
    /// command's screen, or the command in the search, waiting for its
    /// arguments. `instantly` is for a launcher that opened just for this.
    func open(_ item: ResultItem, instantly: Bool) {
        guard let action = item.actions.first else { return }
        isActionMenuOpen = false

        guard asksForArguments(item, action) else {
            run(action, on: item, context: ActionContext(frontmostPID: frontmostPID), replacingScreens: true, instantly: instantly)
            return
        }
        if !routes.isEmpty {
            isNavigatingBack = true
            routes = []
            rootCommand = nil
        }
        // What was typed makes way for the command.
        rememberInput()
        recallIndex = nil
        awaitedSelection = nil
        isQueryPlaced = true
        query = item.title
        refresh(resetSelection: true)
        guard itemIDs.contains(item.id) else {
            focusDefault()
            return
        }
        select(item.id)
        focus(item.arguments.firstIndex(where: \.isRequired).map { .argument($0) } ?? .search)
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
            let actions = item.actions.enumerated().map { index, action in
                CommandAction(
                    title: action.title,
                    symbol: action.symbol,
                    shortcut: shortcut(for: action, at: index),
                    isDestructive: action.isDestructive
                ) { [weak self] in
                    self?.perform(action, on: item)
                }
            }
            // What Inky itself offers for a result.
            var own: [CommandAction] = []
            var disable: [CommandAction] = []
            if engine.hasRanking(item) {
                own.append(CommandAction(title: "Reset Ranking", symbol: "arrow.counterclockwise") { [weak self] in
                    self?.resetRanking(of: item)
                })
            }
            if engine.isCommand(item) {
                own.append(CommandAction(title: "Configure Command…", symbol: "command") { [weak self] in
                    self?.configureCommand(item)
                })
                disable.append(CommandAction(
                    title: "Disable Command",
                    symbol: "eye.slash",
                    shortcut: Self.disableShortcut,
                    isDestructive: true
                ) { [weak self] in
                    self?.disable(item)
                })
            }
            // Whatever destroys something comes last, out of the way, and
            // after it what only takes the result out of sight.
            sections.append(MenuSection(
                title: item.title,
                actions: actions.filter { !$0.isDestructive } + own + actions.filter(\.isDestructive) + disable
            ))
        }

        var general: [CommandAction] = []
        if !showsResults {
            general.append(CommandAction(title: "Show Suggestions", symbol: "list.bullet", shortcut: KeyShortcut("down", [])) { [weak self] in
                self?.browse()
            })
        }
        general.append(CommandAction(title: "Configure Fallback Commands", symbol: ResultsFooter.symbol) { [weak self] in
            self?.configureFallbacks()
        })
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

    /// Lets the item rank by how well it matches again, as if it had never been picked.
    func resetRanking(of item: ResultItem) {
        engine.resetRanking(of: item)
        refresh()
        showToast("Ranking reset")
    }

    /// Hard to press by accident: the command is gone from the results
    /// until it is switched on again in the settings.
    private static let disableShortcut = KeyShortcut("d", [.control, .shift, .command])

    /// Switches a command off: it is not found or suggested anymore, and its
    /// hotkey does nothing.
    func disable(_ item: ResultItem) {
        guard engine.isCommand(item) else { return }
        selectNeighbor(of: item.id)
        engine.commandStore.setEnabled(item.id, false)
        refresh()
        showToast("Disabled “\(item.title)”. Settings → Commands brings it back.")
    }

    /// Moves the selection on to the next result, for when the selected one
    /// is about to go.
    private func selectNeighbor(of id: String) {
        guard route == nil, selectedID == id else { return }
        let ids = itemIDs
        guard let index = ids.firstIndex(of: id) else { return }
        let neighbor = index + 1 < ids.count ? index + 1 : index - 1
        if ids.indices.contains(neighbor) { select(ids[neighbor]) }
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
        if arrivesInstantly {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { routes.append(route) }
        } else {
            routes.append(route)
        }
        focusDefault()
    }

    func popRoute() {
        guard !routes.isEmpty else { return }
        isNavigatingBack = true
        routes.removeLast()
        if routes.isEmpty { rootCommand = nil }
        // The screen that comes back is made anew, and its field with it.
        focusDefault()
    }

    func showQuicklinks() {
        push(.quicklinks(QuicklinkBrowser(store: quicklinks)))
    }

    func editQuicklink(_ quicklink: Quicklink?) {
        push(.quicklinkEditor(QuicklinkDraft(quicklink)))
    }

    /// Shows the editor for a new quicklink that goes to `link`.
    func createQuicklink(to link: String) {
        push(.quicklinkEditor(QuicklinkDraft(link: link)))
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

    func deleteQuicklink(_ quicklink: Quicklink) {
        // In the search, the selection moves on to the next result, as it
        // does in the quicklink browser.
        if let selectedID, selectedID.hasSuffix(quicklink.itemID) {
            selectNeighbor(of: selectedID)
        }
        quicklinks.delete(quicklink.id)
        engine.usage.forget(quicklink.itemID)
        engine.commandStore.forget(quicklink.itemID)
        showToast("Deleted “\(quicklink.name)”")
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
                self?.deleteQuicklink(quicklink)
            },
        ]
        return actions
    }

    // MARK: - Uninstalling

    /// Lists the applications that can be uninstalled.
    func showUninstaller() {
        push(.uninstallBrowser(UninstallBrowser(uninstaller: uninstaller)))
    }

    /// Shows what uninstalling `app` would move to the Trash.
    func reviewUninstall(of app: ApplicationInfo) {
        push(.uninstall(UninstallReview(app: app, uninstaller: uninstaller)))
    }

    /// Moves what is ticked in `review` to the Trash.
    func uninstall(_ review: UninstallReview) {
        // Not before everything that would go has been listed.
        guard !review.isSearching, !review.isUninstalling else { return }
        let items = review.chosen
        guard !items.isEmpty else {
            showToast("Nothing is selected")
            return
        }

        review.isUninstalling = true
        Task {
            defer { review.isUninstalling = false }
            do {
                let outcome = try await uninstaller.uninstall(items, of: review.app)
                didUninstall(review, outcome)
            } catch {
                report(error)
            }
        }
    }

    private func didUninstall(_ review: UninstallReview, _ outcome: UninstallOutcome) {
        if outcome.moved.contains(where: \.isApplication) {
            let id = ApplicationModule.itemID(for: review.app.path)
            engine.usage.forget(id)
            engine.commandStore.forget(id)
            applicationsDidChange()
        }
        // Back to where the user came from, unless they have left already.
        if case .uninstall(let current) = route, current === review {
            popRoute()
            if case .uninstallBrowser(let browser) = route {
                // What was typed found the application that is gone now.
                browser.query = ""
                browser.reload()
            }
        }

        let summary = outcome.summary(of: review.app.name)
        if isVisible() {
            showToast(summary)
        } else if !outcome.left.isEmpty {
            // The launcher closes when macOS asks for a password. Only what
            // went wrong is worth an alert.
            Alerts.show(error: summary)
        }
    }

    // MARK: - Clipboard history

    /// Shows the clipboard history.
    func showClipboard() {
        if case .clipboard = route { return }
        push(.clipboard(ClipboardBrowser(history: clipboard)))
    }

    /// The application the user was in, which is where pasting goes.
    private var pasteTarget: String? {
        frontmostPID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
    }

    /// What the clipboard history offers for an entry. The first runs on Return.
    func actions(for clip: Clip, in browser: ClipboardBrowser) -> [CommandAction] {
        // Without an application to paste into, as when Inky's own settings
        // are in front, there is only copying.
        let target = pasteTarget
        let pastes = pastesOnReturn() && target != nil
        var actions: [CommandAction] = []
        if let target {
            actions.append(CommandAction(
                title: "Paste into \(target)",
                symbol: "doc.on.clipboard",
                shortcut: pastes ? KeyShortcut("return", []) : KeyShortcut("return")
            ) { [weak self] in
                self?.paste(clip)
            })
        }
        let copy = CommandAction(
            title: pastes ? "Copy" : "Copy to Clipboard",
            symbol: "doc.on.doc",
            shortcut: pastes ? KeyShortcut("c") : KeyShortcut("return", [])
        ) { [weak self] in
            self?.copy(clip)
        }
        actions.insert(copy, at: pastes ? actions.count : 0)

        if clip.hasFormatting, target != nil {
            actions.append(CommandAction(title: "Paste as Plain Text", symbol: "textformat", shortcut: KeyShortcut("return", [.option])) { [weak self] in
                self?.paste(clip, asPlainText: true)
            })
        }
        switch clip.kind {
        case .link:
            actions.append(CommandAction(title: "Open Link", symbol: "arrow.up.forward", shortcut: KeyShortcut("o")) { [weak self] in
                self?.open(clip)
            })
        case .file, .path:
            actions.append(CommandAction(title: "Show in Finder", symbol: "folder", shortcut: KeyShortcut("o")) { [weak self] in
                self?.open(clip)
            })
        case .text, .code, .color, .image:
            break
        }
        actions.append(CommandAction(title: clip.isPinned ? "Unpin" : "Pin", symbol: clip.isPinned ? "pin.slash" : "pin", shortcut: KeyShortcut("p")) { [weak self] in
            guard let self else { return }
            // It moves to the pinned entries or back, and stays selected.
            browser.selectedID = clip.id
            Task { await self.clipboard.setPinned(clip, !clip.isPinned) }
        })
        if clip.isPinned {
            actions.append(CommandAction(title: "Rename", symbol: "pencil", shortcut: KeyShortcut("r")) {
                browser.selectedID = clip.id
                browser.beginRenaming()
            })
        }
        actions.append(CommandAction(title: "Delete", symbol: "trash", shortcut: KeyShortcut("x", [.control]), isDestructive: true) { [weak self] in
            guard let self else { return }
            browser.selectNeighbor(of: clip.id)
            Task { await self.clipboard.delete(clip) }
        })
        return actions
    }

    /// Runs what Return does for an entry, as a double click does.
    func runPrimaryAction(on clip: Clip, in browser: ClipboardBrowser) {
        actions(for: clip, in: browser).first?.run()
    }

    /// Puts an entry on the clipboard and closes.
    private func copy(_ clip: Clip) {
        Task {
            do {
                try await clipboard.copy(clip)
                dismiss()
            } catch {
                report(error)
            }
        }
    }

    /// Puts an entry on the clipboard and pastes it into the application
    /// the user was in.
    private func paste(_ clip: Clip, asPlainText: Bool = false) {
        Task {
            do {
                try await clipboard.copy(clip, asPlainText: asPlainText)
            } catch {
                report(error)
                return
            }
            guard pressesKeys else {
                dismiss()
                return
            }
            guard KeyboardPaste.isAllowed else {
                // It is on the clipboard, to be pasted by hand this once.
                showToast("Copied. To paste for you, Inky needs Accessibility access.")
                KeyboardPaste.requestAccess()
                return
            }
            dismissThen {
                // A moment for the application to take the keyboard back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    KeyboardPaste.paste()
                }
            }
        }
    }

    /// Opens a link, or shows files in Finder.
    private func open(_ clip: Clip) {
        Task {
            guard let text = await clipboard.store.payload(of: clip.id)?.text else { return }
            do {
                if clip.kind == .link {
                    let url = try QuicklinkOpener.url(from: text)
                    guard NSWorkspace.shared.open(url) else { throw InkyError("Could not open \(url.absoluteString)") }
                } else {
                    let paths = text.split(separator: "\n").map { ClipClassifier.expandedPath(String($0)) }
                    let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
                    guard !existing.isEmpty else {
                        throw InkyError(paths.count == 1 ? "The file is no longer there" : "The files are no longer there")
                    }
                    NSWorkspace.shared.activateFileViewerSelecting(existing.map { URL(fileURLWithPath: $0) })
                }
                dismiss()
            } catch {
                report(error)
            }
        }
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
            case ("tab", []), ("tab", .shift):
                // With Full Keyboard Access the buttons take the keyboard
                // too, and Tab is left to macOS. Otherwise it goes from one
                // field to the other: left to itself, Tab in the link, which
                // has several lines, leaves the keyboard with neither.
                guard !NSApp.isFullKeyboardAccessEnabled else { return false }
                focus(focusTarget == .quicklinkName ? .quicklinkLink : .quicklinkName)
            default: return false
            }
            return true
        case .uninstallBrowser(let browser):
            return handleKey(key, modifiers, in: browser)
        case .uninstall(let review):
            return handleKey(key, modifiers, in: review)
        case .clipboard(let browser):
            return handleKey(key, modifiers, in: browser, event)
        }
    }

    private func handleKey(_ key: String, _ modifiers: KeyShortcut.Modifiers, in browser: ClipboardBrowser, _ event: NSEvent) -> Bool {
        if browser.renaming != nil {
            switch (key, modifiers) {
            case ("return", []): browser.commitRenaming()
            case ("escape", []): browser.renaming = nil
            // Everything else is typed into the name.
            default: return false
            }
            return true
        }

        switch (key, modifiers) {
        case ("down", []), ("n", .control), ("j", .control): browser.moveSelection(by: 1)
        case ("up", []), ("p", .control), ("k", .control): browser.moveSelection(by: -1)
        case ("tab", []): browser.cycleFilter(by: 1)
        case ("tab", .shift): browser.cycleFilter(by: -1)
        case ("escape", []):
            if browser.query.isEmpty {
                popRoute()
            } else {
                browser.query = ""
            }
        default:
            guard let clip = browser.selected else { return false }
            if key == "c", modifiers == .command {
                // What is selected in the filter is what ⌘C means there.
                if let editor = event.window?.firstResponder as? NSTextView, editor.selectedRange().length > 0 {
                    return false
                }
                copy(clip)
                return true
            }
            guard let action = actions(for: clip, in: browser).first(where: { action in
                action.shortcut.map { $0.key == key && $0.modifiers == modifiers } ?? false
            }) else { return false }
            action.run()
        }
        return true
    }

    private func handleKey(_ key: String, _ modifiers: KeyShortcut.Modifiers, in browser: UninstallBrowser) -> Bool {
        switch (key, modifiers) {
        case ("down", []), ("n", .control), ("j", .control): browser.moveSelection(by: 1)
        case ("up", []), ("p", .control), ("k", .control): browser.moveSelection(by: -1)
        case ("return", []):
            if let app = browser.selected { reviewUninstall(of: app) }
        case ("escape", []):
            if browser.query.isEmpty {
                popRoute()
            } else {
                browser.query = ""
            }
        default: return false
        }
        return true
    }

    private func handleKey(_ key: String, _ modifiers: KeyShortcut.Modifiers, in review: UninstallReview) -> Bool {
        switch (key, modifiers) {
        case ("down", []), ("n", .control), ("j", .control): review.moveCursor(by: 1)
        case ("up", []), ("p", .control), ("k", .control): review.moveCursor(by: -1)
        // Return ticks and unticks. Uninstalling takes more than the key
        // that led here, pressed once too often.
        case ("return", []), ("space", []): review.toggleCurrent()
        case ("a", .command): review.toggleAll()
        case ("return", .command): uninstall(review)
        case ("o", .command):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: review.cursor)])
            dismiss()
        case ("escape", []): popRoute()
        // There is nothing to type into here. Letters would only beep.
        default: return modifiers.subtracting(.shift).isEmpty
        }
        return true
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
        // The arrow keys go through the history while it is being gone
        // through. The others always move the selection.
        case ("down", []):
            if recallIndex != nil {
                recall(by: -1)
            } else if showsResults {
                moveSelection(by: 1)
            } else {
                browse()
            }
        case ("n", .control), ("j", .control):
            if showsResults { moveSelection(by: 1) } else { browse() }
        case ("up", []):
            if recalls { recall(by: 1) } else { moveSelection(by: -1) }
        case ("p", .control), ("k", .control):
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
                clearQuery()
            } else if isBrowsing {
                isBrowsing = false
                refresh()
            } else {
                dismiss()
            }
        default:
            guard let item = selectedItem else { return false }
            if key == Self.disableShortcut.key, modifiers == Self.disableShortcut.modifiers, engine.isCommand(item) {
                disable(item)
                return true
            }
            guard let action = item.actions.first(where: { action in
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
