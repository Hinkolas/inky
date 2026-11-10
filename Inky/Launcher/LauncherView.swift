import InkyCore
import SwiftUI

struct LauncherView: View {
    let model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.route {
            case .quicklinkEditor(let draft):
                RouteHeader(title: draft.isNew ? "Create Quicklink" : "Edit Quicklink") {
                    model.popRoute()
                }
                Divider()
                ScrollView {
                    QuicklinkForm(draft: draft)
                        .padding(.horizontal, 60)
                        .padding(.vertical, 28)
                }
            case nil:
                SearchBar(model: model)
                Divider()
                ResultList(model: model)
            }
            Divider()
            FooterBar(model: model)
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isActionMenuOpen {
                ActionMenu(model: model)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: LauncherMetrics.cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.12))
                .allowsHitTesting(false)
        }
        .frame(width: LauncherMetrics.size.width, height: LauncherMetrics.size.height)
    }
}

// MARK: - Search bar

private struct SearchBar: View {
    let model: LauncherModel
    @FocusState private var focus: LauncherModel.FocusTarget?

    private static let placeholder = "Search apps, commands and files…"
    private static let fontSize: CGFloat = 20

    var body: some View {
        let arguments = model.selectedItem?.arguments ?? []

        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

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
        }
        .padding(.horizontal, 18)
        .frame(height: LauncherMetrics.searchBarHeight)
        .onChange(of: model.focusTick, initial: true) {
            focus = model.focusTarget
        }
        .onChange(of: focus) { _, newValue in
            if let newValue { model.focusDidMove(to: newValue) }
        }
    }

    private var queryWidth: CGFloat {
        let text = model.query.isEmpty ? Self.placeholder : model.query
        return min(380, textWidth(text, size: Self.fontSize) + 6)
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
            .frame(width: min(220, max(64, textWidth(text.isEmpty ? placeholder : text, size: Self.fontSize) + 6)))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.18)))
            }
            .help(name)
    }
}

private func textWidth(_ text: String, size: CGFloat) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
}

private struct RouteHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Back (esc)")

            Text(title)
                .font(.system(size: 17, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: LauncherMetrics.searchBarHeight)
    }
}

// MARK: - Results

private struct ResultList: View {
    let model: LauncherModel

    var body: some View {
        if model.sections.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                Text("No results")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 6).id(Self.top)
                        ForEach(model.sections) { section in
                            Text(section.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 18)
                                .padding(.top, 8)
                                .padding(.bottom, 5)

                            ForEach(section.items) { item in
                                ResultRow(item: item, isSelected: item.id == model.selectedID)
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
                        Color.clear.frame(height: 6)
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

    private static let top = "inky.list.top"
}

private struct ResultRow: View {
    let item: ResultItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: item.icon, size: 24)
            Text(item.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(item.kind)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .frame(height: LauncherMetrics.rowHeight)
        .background(
            isSelected ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Footer and actions

private struct FooterBar: View {
    let model: LauncherModel

    var body: some View {
        HStack(spacing: 10) {
            if let toast = model.toast {
                Label(toast, systemImage: "info.circle.fill")
                    .lineLimit(1)
            } else {
                Label("Inky", systemImage: "drop.fill")
            }
            Spacer()

            if case .quicklinkEditor = model.route {
                FooterButton(title: "Save Quicklink", keys: ["⌘", "↵"]) { model.saveQuicklink() }
            } else if let item = model.selectedItem, let primary = item.actions.first {
                FooterButton(title: primary.title, keys: ["↵"]) { model.runPrimaryAction() }
                Divider().frame(height: 14)
                FooterButton(title: "Actions", keys: ["⌘", "K"]) { model.toggleActionMenu() }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: LauncherMetrics.footerHeight)
        .background(.primary.opacity(0.03))
    }
}

private struct FooterButton: View {
    let title: String
    let keys: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.primary)
                Keycaps(keys)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ActionMenu: View {
    let model: LauncherModel

    var body: some View {
        if let item = model.selectedItem {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                ForEach(Array(item.actions.enumerated()), id: \.offset) { index, action in
                    HStack(spacing: 8) {
                        Image(systemName: action.symbol)
                            .frame(width: 18)
                        Text(action.title)
                        Spacer(minLength: 16)
                        Keycaps(model.shortcutSymbols(for: action, at: index))
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(
                        index == model.actionMenuIndex ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.perform(action, on: item) }
                }
            }
            .padding(6)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.14))
            }
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .padding(.trailing, 8)
            .padding(.bottom, LauncherMetrics.footerHeight + 6)
        }
    }
}
