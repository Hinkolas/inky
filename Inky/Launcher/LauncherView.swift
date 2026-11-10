import InkyCore
import SwiftUI

/// Everything the launcher shows, laid out from the top of a transparent canvas.
struct LauncherView: View {
    let model: LauncherModel

    var body: some View {
        ZStack(alignment: .top) {
            // Where the canvas is see-through, clicks go to whatever is behind
            // the panel. What does arrive here landed on a shadow.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.dismiss() }

            VStack(spacing: LauncherMetrics.gap) {
                switch model.route {
                case nil:
                    SearchScreen(model: model)
                case .quicklinks(let browser):
                    QuicklinkBrowserScreen(model: model, browser: browser)
                case .quicklinkEditor(let draft):
                    QuicklinkEditorScreen(model: model, draft: draft)
                }

                if let toast = model.toast {
                    Toast(message: toast)
                } else if model.route == nil, model.showsResults {
                    HintBar(model: model)
                }
            }
            // The gaps between the floating parts belong to the launcher.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }
            .padding(.top, LauncherMetrics.margin.top + (model.route == nil ? LauncherMetrics.searchDrop : 0))
        }
        .frame(width: LauncherMetrics.canvas.width, height: LauncherMetrics.canvas.height)
    }
}

// MARK: - Search

private struct SearchScreen: View {
    let model: LauncherModel

    var body: some View {
        VStack(spacing: LauncherMetrics.gap) {
            SearchBar(model: model)
            if model.showsResults {
                ResultsCard(model: model)
            }
        }
        .frame(width: LauncherMetrics.searchWidth)
        .overlay(alignment: .topTrailing) {
            if model.isActionMenuOpen {
                ActionMenu(model: model)
                    .offset(y: LauncherMetrics.barHeight + 6)
            }
        }
    }
}

private struct SearchBar: View {
    let model: LauncherModel
    @FocusState private var focus: LauncherModel.FocusTarget?

    private static let placeholder = "Search apps, commands and files"
    private static let fontSize: CGFloat = 17

    var body: some View {
        let arguments = model.selectedItem?.arguments ?? []

        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 20)

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
                    isFocused: focus == .argument(index)
                )
                .focused($focus, equals: .argument(index))
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
                        .frame(width: 22, height: 22)
                        .background(Theme.subtleFill, in: Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .help("Clear (esc)")
            }

            CircleButton(symbol: "ellipsis", help: "Actions (⌘K)") {
                model.toggleActionMenu()
            }
        }
        .padding(.leading, 17)
        .padding(.trailing, 8)
        .frame(height: LauncherMetrics.barHeight)
        .glassSurface(cornerRadius: nil)
        .onChange(of: model.focusTick, initial: true) {
            focus = model.focusTarget
        }
        .onChange(of: focus) { _, newValue in
            if let newValue { model.focusDidMove(to: newValue) }
        }
    }

    private var queryWidth: CGFloat {
        let text = model.query.isEmpty ? Self.placeholder : model.query
        return min(340, textWidth(text, size: Self.fontSize) + 6)
    }
}

private struct ArgumentField: View {
    let name: String
    let hint: String?
    @Binding var text: String
    let isFocused: Bool

    private static let fontSize: CGFloat = 14

    var body: some View {
        let placeholder = hint ?? name
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: Self.fontSize))
            .frame(width: min(200, max(64, textWidth(text.isEmpty ? placeholder : text, size: Self.fontSize) + 6)))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Theme.fieldFill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isFocused ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fieldStroke),
                    lineWidth: isFocused ? 1.5 : 1
                )
            }
            .help(name)
    }
}

private func textWidth(_ text: String, size: CGFloat) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
}

// MARK: - Results

private struct ResultsCard: View {
    let model: LauncherModel

    private static let rowSlot = LauncherMetrics.rowHeight + 1
    private static let bottomInset: CGFloat = 8
    private static let top = "inky.list.top"

    var body: some View {
        Group {
            if model.sections.isEmpty {
                Text("No results")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
            } else {
                list
                    .frame(height: min(LauncherMetrics.listMaxHeight, contentHeight))
                    .clipShape(SurfaceShape(cornerRadius: LauncherMetrics.cardRadius))
            }
        }
        .glassSurface(cornerRadius: LauncherMetrics.cardRadius)
    }

    /// Known from the data, so the card can be exactly as tall as its rows.
    private var contentHeight: CGFloat {
        model.sections.reduce(Self.bottomInset) { height, section in
            height + LauncherMetrics.sectionHeaderHeight + CGFloat(section.items.count) * Self.rowSlot
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top)
                    ForEach(model.sections) { section in
                        PanelLabel(section.title)
                            .padding(.horizontal, 18)
                            .padding(.top, 5)
                            .frame(height: LauncherMetrics.sectionHeaderHeight)

                        ForEach(section.items) { item in
                            let isSelected = item.id == model.selectedID
                            ResultRow(item: item, isSelected: isSelected, primaryAction: isSelected ? item.actions.first?.title : nil)
                                .frame(height: Self.rowSlot)
                                .id(item.id)
                                .onTapGesture(count: 2) {
                                    model.select(item.id)
                                    model.runPrimaryAction()
                                }
                                .simultaneousGesture(TapGesture().onEnded {
                                    model.select(item.id)
                                })
                        }
                    }
                    Color.clear.frame(height: Self.bottomInset)
                }
            }
            .scrollIndicators(.never)
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                if id == model.firstItemID {
                    // Bring the section title back into view too.
                    proxy.scrollTo(Self.top, anchor: .top)
                } else {
                    proxy.scrollTo(id)
                }
            }
        }
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
            IconView(icon: item.icon, size: 24)
                .overlay {
                    if isSelected, case .symbol = item.icon {
                        RoundedRectangle(cornerRadius: 24 * 0.26, style: .continuous).strokeBorder(.white.opacity(0.55))
                    }
                }
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
        HStack(spacing: 16) {
            hint(["↑", "↓"], "Move")
            hint(["⌘", "K"], "Actions")
            hint(["esc"], model.query.isEmpty ? "Close" : "Clear")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .glassSurface(cornerRadius: nil)
    }

    private func hint(_ keys: [String], _ title: String) -> some View {
        HStack(spacing: 6) {
            Keycap(keys)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
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
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
        .padding(7)
        .frame(width: 290)
        .glassSurface(cornerRadius: 16)
    }
}
