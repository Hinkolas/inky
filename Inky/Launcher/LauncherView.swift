import InkyCore
import SwiftUI

/// Everything the launcher shows, laid out from the top of a transparent canvas.
///
/// The bar and the card are the same two surfaces whatever is showing. A
/// screen draws only what goes on them, so going from the search to a command
/// and back moves and resizes the surfaces instead of swapping them.
struct LauncherView: View {
    let model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = Motion(isEnabled: Preferences.shared.animations, reduceMotion: reduceMotion)
        let layout = layout
        let depth = model.routes.count

        ZStack(alignment: .top) {
            // Where the canvas is see-through, clicks go to whatever is behind
            // the panel. What does arrive here landed on a shadow.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.dismiss() }

            VStack(spacing: LauncherMetrics.gap) {
                ZStack(alignment: .top) {
                    LauncherSurfaces(layout: layout, onBack: model.popRoute)

                    // One view whatever it holds, so that what is cut out of
                    // it changes shape instead of being replaced.
                    ZStack(alignment: .top) {
                        switch model.route {
                        case nil:
                            SearchScreen(model: model)
                                .transition(motion.screen(isGoingBack: model.isNavigatingBack))
                        case .quicklinks(let browser):
                            QuicklinkBrowserScreen(model: model, browser: browser)
                                .transition(motion.screen(isGoingBack: model.isNavigatingBack))
                        case .quicklinkEditor(let draft):
                            QuicklinkEditorScreen(model: model, draft: draft)
                                .transition(motion.screen(isGoingBack: model.isNavigatingBack))
                        }
                    }
                    // A screen is laid out at its final size from the start.
                    // Cut to the outline of the surfaces, it never shows
                    // beyond them while they are still on their way.
                    .frame(
                        width: LauncherMetrics.maxContentSize.width,
                        height: LauncherMetrics.maxContentSize.height,
                        alignment: .top
                    )
                    .clipShape(SurfaceOutline(layout))
                    .frame(width: layout.width, height: layout.height, alignment: .top)
                }
                .overlay(alignment: .topTrailing) {
                    ZStack(alignment: .topTrailing) {
                        if model.route == nil, model.isActionMenuOpen {
                            ActionMenu(model: model)
                                .transition(motion.popping(
                                    .scale(scale: 0.9, anchor: UnitPoint(x: 0.92, y: 0)).combined(with: .opacity)
                                ))
                        }
                    }
                    .offset(y: LauncherMetrics.barHeight + 6)
                    .animation(motion.quick, value: model.isActionMenuOpen)
                }
                // Without motion the surfaces may not travel either: one
                // screen fades into the next, each with surfaces of its own.
                .id(motion.level == .reduced ? depth : 0)
                .transition(motion.fade)

                ZStack {
                    if let toast = model.toast {
                        Toast(message: toast)
                            .transition(motion.popping(.offset(y: 8).combined(with: .opacity)))
                    } else if model.route == nil, model.showsResults {
                        HintBar(model: model)
                            .transition(motion.belowCard)
                    }
                }
                .animation(motion.quick, value: model.toast)
            }
            // The gaps between the floating parts belong to the launcher.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }
            // Of two that apply at once the inner one wins: a change of screen.
            .animation(motion.morph, value: depth)
            .animation(motion.resize, value: layout.cardHeight)
            .padding(.top, LauncherMetrics.margin.top)
        }
        .frame(width: LauncherMetrics.canvas.width, height: LauncherMetrics.canvas.height)
        .transaction { transaction in
            // Off means off, whatever asked for the change.
            if motion.level == .off {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .environment(\.motion, motion)
    }

    private var layout: LauncherLayout {
        switch model.route {
        case nil:
            LauncherLayout(
                width: LauncherMetrics.searchWidth,
                hasBackButton: false,
                cardHeight: model.showsResults ? ResultsList.height(for: model.sections) : nil
            )
        case .quicklinks:
            LauncherLayout(command: QuicklinkBrowserScreen.size)
        case .quicklinkEditor:
            LauncherLayout(command: QuicklinkEditorScreen.size)
        }
    }
}

// MARK: - Surfaces

/// Where the launcher's surfaces are.
private nonisolated struct LauncherLayout: Equatable {
    var width: CGFloat
    /// Commands have one, at the leading end of the bar.
    var hasBackButton: Bool
    /// Nil while the bar is all there is.
    var cardHeight: CGFloat?

    /// The bar, and the card below it if there is one.
    var height: CGFloat {
        LauncherMetrics.barHeight + (cardHeight.map { LauncherMetrics.gap + $0 } ?? 0)
    }

    /// Where the bar starts: after the back button, if there is one.
    var barLeading: CGFloat {
        hasBackButton ? LauncherMetrics.barHeight + LauncherMetrics.gap : 0
    }
}

extension LauncherLayout {
    /// A command's: `size` is that of its body card.
    init(command size: CGSize) {
        self.init(width: size.width, hasBackButton: true, cardHeight: size.height)
    }
}

/// The bar, the back button and the card, with nothing on them.
private struct LauncherSurfaces: View {
    let layout: LauncherLayout
    let onBack: () -> Void
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(spacing: LauncherMetrics.gap) {
            ZStack(alignment: .leading) {
                if layout.hasBackButton {
                    BackButton(action: onBack)
                        // It starts out where the search bar began, and comes
                        // out of that end as the bar makes room.
                        .transition(motion.transition(
                            .offset(x: (layout.width - LauncherMetrics.searchWidth) / 2).combined(with: .opacity)
                        ))
                }
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: LauncherMetrics.barHeight)
                    .glassSurface(cornerRadius: nil)
                    .padding(.leading, layout.barLeading)
            }

            // Always there, so that it grows out from under the bar and
            // shrinks back instead of appearing.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: layout.cardHeight ?? 0)
                .glassSurface(cornerRadius: LauncherMetrics.cardRadius)
                .opacity(layout.cardHeight == nil ? 0 : 1)
        }
        .frame(width: layout.width)
        .frame(height: layout.height, alignment: .top)
    }
}

/// The outline of the bar and the card together.
private nonisolated struct SurfaceOutline: Shape {
    var width: CGFloat
    var barLeading: CGFloat
    var cardHeight: CGFloat

    init(_ layout: LauncherLayout) {
        width = layout.width
        barLeading = layout.barLeading
        cardHeight = layout.cardHeight ?? 0
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(width, AnimatablePair(barLeading, cardHeight)) }
        set {
            width = newValue.first
            barLeading = newValue.second.first
            cardHeight = newValue.second.second
        }
    }

    /// Centered at the top of `rect`, as the surfaces are.
    func path(in rect: CGRect) -> Path {
        let leading = rect.midX - width / 2
        let bar = CGRect(
            x: leading + barLeading, y: rect.minY,
            width: max(0, width - barLeading), height: LauncherMetrics.barHeight
        )
        var path = Capsule().path(in: bar)
        if cardHeight > 0 {
            let card = CGRect(x: leading, y: bar.maxY + LauncherMetrics.gap, width: width, height: cardHeight)
            path.addPath(RoundedRectangle(cornerRadius: LauncherMetrics.cardRadius, style: .continuous).path(in: card))
        }
        return path
    }
}

private struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .bold))
                .frame(width: LauncherMetrics.barHeight, height: LauncherMetrics.barHeight)
                .glassSurface(cornerRadius: nil)
        }
        .buttonStyle(PressableButtonStyle())
        .help("Back (esc)")
    }
}

// MARK: - Search

private struct SearchScreen: View {
    let model: LauncherModel
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(spacing: LauncherMetrics.gap) {
            SearchBar(model: model)
            if model.showsResults {
                ResultsList(model: model)
                    .transition(motion.fade)
            }
        }
        .frame(width: LauncherMetrics.searchWidth)
    }
}

private struct SearchBar: View {
    let model: LauncherModel
    @FocusState private var focus: LauncherModel.FocusTarget?
    @Environment(\.motion) private var motion

    private static let placeholder = "Search apps, commands and files"
    private static let fontSize = LauncherMetrics.barFontSize

    var body: some View {
        let arguments = model.selectedItem?.arguments ?? []

        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 24)

            TextField(Self.placeholder, text: Binding(get: { model.query }, set: model.setQuery))
                .textFieldStyle(.plain)
                .font(.system(size: Self.fontSize))
                .focused($focus, equals: .search)
                // With arguments the field hugs its text so they sit right after it.
                .frame(width: arguments.isEmpty ? nil : queryWidth)

            ForEach(Array(arguments.enumerated()), id: \.offset) { index, argument in
                ArgumentField(
                    name: argument.name,
                    hint: argument.defaultValue,
                    text: Binding(
                        get: { index < model.argumentValues.count ? model.argumentValues[index] : "" },
                        set: { model.setArgument(index, $0) }
                    ),
                    isFocused: focus == .argument(index),
                    missingTick: model.missingArgumentTick
                )
                .focused($focus, equals: .argument(index))
                // It only fades in, and pops its own outline: see ArgumentField.
                .transition(.asymmetric(
                    insertion: motion.transition(.opacity),
                    removal: motion.transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                        .animation(motion.exit)
                ))
            }

            if !arguments.isEmpty {
                Spacer(minLength: 0)
            }

            if !model.query.isEmpty {
                Button {
                    model.setQuery("")
                    model.focus(.search)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.primary.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .background(Theme.subtleFill, in: Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .help("Clear (esc)")
                .transition(motion.popping(.scale(scale: 0.5).combined(with: .opacity)))
            }

            CircleButton(symbol: "ellipsis", size: LauncherMetrics.barControlSize, help: "Actions (⌘K)") {
                model.toggleActionMenu()
            }
        }
        .padding(.leading, 19)
        .padding(.trailing, LauncherMetrics.barInset)
        .frame(height: LauncherMetrics.barHeight)
        .animation(motion.quick, value: BarParts(hasQuery: !model.query.isEmpty, arguments: arguments.map(\.name)))
        // Typing must not: the field would lag behind what is typed into it.
        .animation(nil, value: model.query)
        .onChange(of: model.focusTick, initial: true) {
            focus = model.focusTarget
        }
        .onChange(of: focus) { _, newValue in
            if let newValue { model.focusDidMove(to: newValue) }
        }
    }

    private var queryWidth: CGFloat {
        let text = model.query.isEmpty ? Self.placeholder : model.query
        return min(360, textWidth(text, size: Self.fontSize) + 6)
    }

    /// What comes and goes in the bar.
    private struct BarParts: Equatable {
        var hasQuery: Bool
        var arguments: [String]
    }
}

private struct ArgumentField: View {
    let name: String
    let hint: String?
    @Binding var text: String
    let isFocused: Bool
    /// Goes up when an action wanted this argument and it was empty.
    let missingTick: Int

    @Environment(\.motion) private var motion
    @State private var shakes: CGFloat = 0
    @State private var hasArrived = false

    private static let fontSize: CGFloat = 15

    var body: some View {
        let placeholder = hint ?? name
        // As wide as what it says. Typing never makes it narrower than it
        // was empty, so it does not shrink under the first letter.
        let width = max(textWidth(placeholder, size: Self.fontSize), textWidth(text, size: Self.fontSize))
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: Self.fontSize))
            // The editor AppKit puts over a field is a point taller than the
            // field SwiftUI made and stands out over its top edge, so text
            // being edited sits a point higher. This puts it back.
            .offset(y: isFocused ? 1 : 0)
            .frame(width: min(200, width + 6))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                // Only the outline pops in. A field that takes the keyboard
                // while it is being scaled keeps its text where it was at
                // that moment, a point or two off, so the field stays put.
                // Round ends, not the smooth ones a capsule has unasked. Those
                // start to turn well before the end, which bends the long
                // sides by a pixel and shows as a step in the focus ring.
                Capsule(style: .circular)
                    .fill(Theme.fieldFill)
                    .overlay {
                        Capsule(style: .circular).strokeBorder(
                            isFocused ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fieldStroke),
                            lineWidth: isFocused ? 1.5 : 1
                        )
                    }
                    .scaleEffect(hasArrived || motion.level != .full ? 1 : 0.9, anchor: .leading)
            }
            .onAppear {
                withAnimation(motion.quick) { hasArrived = true }
            }
            .help(name)
            .modifier(Shake(shakes: shakes))
            .onChange(of: missingTick) {
                guard isFocused else { return }
                withAnimation(motion.shake) { shakes += 1 }
            }
    }
}

private func textWidth(_ text: String, size: CGFloat) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
}

// MARK: - Results

private struct ResultsList: View {
    let model: LauncherModel

    private static let rowSlot = LauncherMetrics.rowHeight + 1
    private static let emptyHeight: CGFloat = 124
    private static let top = "inky.list.top"
    private static let end = "inky.list.end"

    var body: some View {
        Group {
            if model.sections.isEmpty {
                NoResults(configureFallbacks: model.configureFallbacks)
            } else {
                list
                    .clipShape(SurfaceShape(cornerRadius: LauncherMetrics.cardRadius))
            }
        }
        .frame(height: Self.height(for: model.sections))
        // Results change with every key. They are there at once, and the
        // card catches up around them.
        .transaction { $0.animation = nil }
    }

    /// A section title or a result, in the order they are shown.
    enum Line: Identifiable {
        case header(String)
        case item(ResultItem)

        /// A result's own id, so `scrollTo` finds it by that.
        var id: String {
            switch self {
            case .header(let title): "inky.section.\(title)"
            case .item(let item): item.id
            }
        }
    }

    static func lines(for sections: [ResultSection]) -> [Line] {
        sections.flatMap { section in
            [.header(section.title)] + section.items.map(Line.item)
        }
    }

    /// Known from the data, so the card can be exactly as tall as its rows.
    static func height(for sections: [ResultSection]) -> CGFloat {
        guard !sections.isEmpty else { return emptyHeight }
        let rows = sections.reduce(ResultsFooter.height) { height, section in
            height + LauncherMetrics.sectionHeaderHeight + CGFloat(section.items.count) * rowSlot
        }
        return min(LauncherMetrics.listMaxHeight, rows)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top)
                    // One flat list rather than a ForEach per section. A row
                    // that moved into another section, such as into the top
                    // hit as the query grew, otherwise kept its old look and
                    // was not drawn as selected.
                    ForEach(Self.lines(for: model.sections)) { line in
                        switch line {
                        case .header(let title):
                            PanelLabel(title)
                                .padding(.horizontal, 18)
                                .padding(.top, 5)
                                .frame(height: LauncherMetrics.sectionHeaderHeight)
                        case .item(let item):
                            let isSelected = item.id == model.selectedID
                            ResultRow(item: item, isSelected: isSelected, primaryAction: isSelected ? item.actions.first?.title : nil)
                                .frame(height: Self.rowSlot)
                                .onTapGesture(count: 2) {
                                    model.select(item.id)
                                    model.runPrimaryAction()
                                }
                                .simultaneousGesture(TapGesture().onEnded {
                                    model.select(item.id)
                                })
                        }
                    }
                    ResultsFooter(action: model.configureFallbacks)
                        .id(Self.end)
                }
            }
            .scrollIndicators(.never)
            .onChange(of: model.selectedID) { previous, id in
                guard let id else { return }
                let ids = model.itemIDs
                guard let index = ids.firstIndex(of: id) else { return }

                if index == 0 {
                    // Bring the section title back into view too.
                    proxy.scrollTo(Self.top, anchor: .top)
                } else if index == ids.count - 1 {
                    // And the footer.
                    proxy.scrollTo(Self.end, anchor: .bottom)
                } else {
                    // Scroll for the row after the selected one, in the
                    // direction of travel. The selection then never touches
                    // the edge of the card, whose corners would cut into it.
                    let wasBelow = previous.flatMap(ids.firstIndex(of:)).map { $0 > index } ?? false
                    proxy.scrollTo(ids[wasBelow ? index - 1 : index + 1])
                }
            }
        }
    }
}

/// Ends every list, as tall as a section's title above its rows.
///
/// The card's corners are rounder than a row's. A selected row right at the
/// end of the card would pinch against them; a quiet line of text does not.
struct ResultsFooter: View {
    static let height = LauncherMetrics.sectionHeaderHeight
    static let title = "Configure Fallback Commands…"
    static let symbol = "slider.horizontal.3"

    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(Self.title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
        .padding(.horizontal, 18)
        .padding(.bottom, 5)
        .frame(height: Self.height)
    }
}

/// Shown when nothing was found and there is no fallback to offer either,
/// which is when one would have helped.
private struct NoResults: View {
    let configureFallbacks: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("No results")
                .font(.system(size: 14, weight: .semibold))
            Text("Fallback commands send a search like this somewhere else, such as the web.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            Button(action: configureFallbacks) {
                HStack(spacing: 6) {
                    Image(systemName: ResultsFooter.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(ResultsFooter.title)
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .padding(.leading, 11)
                .padding(.trailing, 14)
                .frame(height: 28)
                .background(Theme.controlFill, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.controlStroke) }
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ResultRow: View {
    let item: ResultItem
    let isSelected: Bool
    /// Shown with its keys in place of the kind, on the selected row.
    let primaryAction: String?

    var body: some View {
        let dimmed = isSelected ? AnyShapeStyle(Theme.onAccent.opacity(0.82)) : AnyShapeStyle(.secondary)

        HStack(spacing: 12) {
            IconView(icon: item.icon, size: 24, outline: isSelected ? 0.55 : 0)
            Text(item.title)
                .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(dimmed)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let primaryAction {
                HStack(spacing: 6) {
                    Text(primaryAction)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .padding(.trailing, 2)
                    Keycap(["↵"], tone: .onAccent)
                    Keycap(["⌘", "K"], tone: .onAccent)
                }
                .layoutPriority(1)
            } else {
                Text(item.kind)
                    .font(.system(size: 13.5))
                    .foregroundStyle(dimmed)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
        .padding(.leading, 10)
        .padding(.trailing, isSelected ? 8 : 10)
        .frame(height: LauncherMetrics.rowHeight)
        .background(
            isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Below the card

/// The keys that matter right now, on their own small surface so they stay
/// readable over any wallpaper.
private struct HintBar: View {
    let model: LauncherModel

    var body: some View {
        let closes = model.query.isEmpty

        HStack(spacing: 16) {
            hint(["↑"], ["↓"]) { label("Move") }
            hint(["⌘", "K"]) { label("Actions") }
            hint(["esc"]) {
                // Both are always there and one is seen. The bar keeps its
                // width, and neither has to find its place while the bar
                // is on the move.
                ZStack(alignment: .leading) {
                    label("Close")
                        .opacity(closes ? 1 : 0)
                        .accessibilityHidden(!closes)
                    label("Clear")
                        .opacity(closes ? 0 : 1)
                        .accessibilityHidden(closes)
                }
            }
        }
        // As wide as what it says, whatever room it is given while the
        // launcher around it changes size.
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: 32)
        .glassSurface(cornerRadius: nil)
    }

    /// One cap per chord: keys pressed together share a cap, keys that are
    /// alternatives each get their own.
    private func hint(_ chords: [String]..., @ViewBuilder title: () -> some View) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(chords, id: \.self) { Keycap($0) }
            }
            title()
        }
    }

    /// A word that is never broken or cut short.
    private func label(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct Toast: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle.fill")
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .glassSurface(cornerRadius: nil)
    }
}

// MARK: - Actions menu

private struct ActionMenu: View {
    let model: LauncherModel

    /// Each section with the position of its first action in the whole menu.
    private var numbered: [(section: LauncherModel.MenuSection, start: Int)] {
        var start = 0
        return model.menuSections.map { section in
            defer { start += section.actions.count }
            return (section, start)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(numbered, id: \.section.id) { entry in
                if entry.start > 0 {
                    PanelDivider().padding(.vertical, 4).padding(.horizontal, 8)
                }
                PanelLabel(entry.section.title)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)

                ForEach(Array(entry.section.actions.enumerated()), id: \.offset) { index, action in
                    let isSelected = entry.start + index == model.actionMenuIndex
                    Button {
                        model.runMenuAction(action)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: action.symbol)
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(width: 18)
                            Text(action.title)
                                .font(.system(size: 13.5, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 16)
                            Keycap(action.shortcut?.symbols ?? [], tone: isSelected ? .onAccent : .plain)
                        }
                        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
                        .padding(.leading, 9)
                        .padding(.trailing, 7)
                        .frame(height: 32)
                        .background(
                            isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                    .buttonStyle(PressableButtonStyle(pressedScale: 1))
                }
            }
        }
        .padding(7)
        .frame(width: 290)
        .glassSurface(cornerRadius: 16)
    }
}
