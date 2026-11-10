import InkyCore
import SwiftUI

// The parts a command's screen is built from. A command takes over the
// launcher with a `CommandScreen`: a back button and a header pill it
// configures, above a body card it fills. Inside the card, a `Sidebar`
// narrows what is shown and a `SidePanel` previews, inspects or assists.
// Built-in commands use these directly; extensions will describe the same
// parts as data.

/// Something a command offers to do, with the keys that trigger it.
struct CommandAction: Identifiable {
    var title: String
    /// SF Symbol name.
    var symbol: String
    var shortcut: KeyShortcut?
    var isDestructive = false
    var run: () -> Void

    var id: String { title }
}

// MARK: - Screen

/// A command's screen: back button, header pill and body card.
///
/// The header pill shows the command's icon and where the user is, then
/// `header` (a filter field, say) and, at its trailing edge, `accessory`
/// (a button or a menu).
struct CommandScreen<Header: View, Accessory: View, Content: View>: View {
    let icon: Icon
    /// Where the user is, outermost first: `["Quicklinks", "New Quicklink"]`.
    let path: [String]
    /// The size of the body card. The header is as wide.
    let size: CGSize
    let onBack: () -> Void
    let header: Header
    let accessory: Accessory
    let content: Content

    init(
        icon: Icon,
        path: [String],
        size: CGSize,
        onBack: @escaping () -> Void,
        @ViewBuilder header: () -> Header,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.path = path
        self.size = size
        self.onBack = onBack
        self.header = header()
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: LauncherMetrics.gap) {
            HStack(spacing: LauncherMetrics.gap) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: LauncherMetrics.barHeight, height: LauncherMetrics.barHeight)
                        .glassSurface(cornerRadius: nil)
                }
                .buttonStyle(PressableButtonStyle())
                .help("Back (esc)")

                HStack(spacing: 10) {
                    IconView(icon: icon, size: 30, shape: .circle)
                    Breadcrumb(path: path)
                    if Header.self != EmptyView.self {
                        Rectangle()
                            .fill(Theme.separator)
                            .frame(width: 1, height: 22)
                            .padding(.horizontal, 2)
                        header.layoutPriority(1)
                    }
                    Spacer(minLength: 8)
                    accessory
                        .fixedSize()
                        .layoutPriority(2)
                }
                .padding(.leading, 9)
                .padding(.trailing, 8)
                .frame(height: LauncherMetrics.barHeight)
                .glassSurface(cornerRadius: nil)
            }

            content
                .frame(width: size.width, height: size.height)
                .glassSurface(cornerRadius: LauncherMetrics.cardRadius)
        }
        .frame(width: size.width)
    }
}

extension CommandScreen where Header == EmptyView {
    init(
        icon: Icon,
        path: [String],
        size: CGSize,
        onBack: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.init(icon: icon, path: path, size: size, onBack: onBack, header: { EmptyView() }, accessory: accessory, content: content)
    }
}

private struct Breadcrumb: View {
    let path: [String]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(path.enumerated()), id: \.offset) { index, title in
                let isLast = index == path.count - 1
                Text(title)
                    .font(.system(size: 15, weight: isLast ? .semibold : .regular))
                    .foregroundStyle(isLast ? .primary : .secondary)
                    .lineLimit(1)
                if !isLast {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .fixedSize()
    }
}

/// The text field of a header pill, for narrowing what the command shows.
struct FilterField: View {
    @Binding var text: String
    let prompt: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .focused(focus)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Panels

/// A panel at the leading edge of the body card, for choosing what the
/// content shows: filters, folders, saved searches.
struct Sidebar<Content: View>: View {
    var width: CGFloat = 184
    @ViewBuilder let content: Content

    var body: some View {
        InsetPanel(width: width, padding: 8) { content }
    }
}

/// A panel at the trailing edge of the body card, for what belongs to the
/// content without being part of it: a preview, details, actions, a picker.
struct SidePanel<Content: View>: View {
    var width: CGFloat = 270
    @ViewBuilder let content: Content

    var body: some View {
        InsetPanel(width: width, padding: 14) { content }
    }
}

private struct InsetPanel<Content: View>: View {
    let width: CGFloat
    let padding: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LauncherMetrics.panelRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.panelFill, in: shape)
            .overlay { shape.strokeBorder(Theme.panelStroke) }
            .padding(LauncherMetrics.panelInset)
    }
}

/// The small heading above a group of rows or a field.
struct PanelLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// One choice in a sidebar.
struct SidebarRow: View {
    let title: String
    let symbol: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text(count, format: .number)
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .frame(height: 33)
            .background(
                isSelected ? AnyShapeStyle(Theme.subtleFill) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Lists

/// A row with a title, a line below it and something at the trailing edge.
struct DetailRow: View {
    static let height: CGFloat = 51

    let icon: Icon
    let title: String
    let subtitle: String
    var trailing: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            IconView(icon: icon, size: 30)
                .overlay {
                    if isSelected, case .symbol = icon {
                        RoundedRectangle(cornerRadius: 30 * 0.26, style: .continuous).strokeBorder(.white.opacity(0.5))
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: Self.height - 1)
        .background(
            isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: LauncherMetrics.rowRadius, style: .continuous)
        )
        .frame(height: Self.height)
        .contentShape(Rectangle())
    }
}

// MARK: - Side panel content

/// Text shown as it is, in a box: a snippet, a link, a path.
struct PreviewBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.fieldStroke)
            }
    }
}

/// Facts about the selected item, as names and values.
struct MetadataList: View {
    let rows: [(name: String, value: String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
            ForEach(rows, id: \.name) { row in
                GridRow {
                    Text(row.name)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(row.value)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 12.5))
    }
}

/// What can be done with the selected item. The first action is the one
/// Return runs, and is drawn as such.
struct ActionList: View {
    let actions: [CommandAction]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                let isPrimary = index == 0
                Button(action: action.run) {
                    HStack(spacing: 8) {
                        Text(action.title)
                            .font(.system(size: 13.5, weight: isPrimary ? .semibold : .medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Keycap(action.shortcut?.symbols ?? [], tone: isPrimary ? .onAccent : .plain)
                    }
                    .foregroundStyle(
                        isPrimary ? AnyShapeStyle(Theme.onAccent)
                            : action.isDestructive ? AnyShapeStyle(Theme.destructive)
                            : AnyShapeStyle(.primary)
                    )
                    .padding(.leading, 11)
                    .padding(.trailing, 7)
                    .frame(height: 32)
                    .background(
                        isPrimary ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }
}

/// A hairline between groups in a panel.
struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
    }
}

// MARK: - Forms

/// A box of form rows, with hairlines between them.
struct FormGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 { PanelDivider() }
                    subview
                }
            }
        }
        .background(Theme.panelFill, in: shape)
        .overlay { shape.strokeBorder(Theme.panelStroke) }
    }
}

/// A named control in a `FormGroup`.
struct FormRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
            Spacer(minLength: 12)
            control
        }
        .padding(.leading, 13)
        .padding(.trailing, 9)
        .frame(height: 48)
    }
}

/// The label of a menu that picks one value: the value, then the arrows.
struct PopupLabel<Leading: View>: View {
    let title: String
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: 7) {
            leading
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.controlStroke)
        }
        .shadow(color: Theme.controlShadow, radius: 2, y: 1)
        .contentShape(Rectangle())
    }
}

/// A text area's box.
struct FieldBox: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(Theme.fieldFill, in: shape)
            .overlay {
                shape.strokeBorder(isFocused ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fieldStroke), lineWidth: isFocused ? 1.5 : 1)
            }
    }
}
