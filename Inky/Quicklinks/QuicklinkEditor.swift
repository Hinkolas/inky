import AppKit
import InkyCore
import SwiftUI

/// Creates or edits a quicklink: a form, and a side panel that helps write
/// the link and shows what comes of it.
struct QuicklinkEditorScreen: View {
    let model: LauncherModel
    @Bindable var draft: QuicklinkDraft
    @FocusState private var focus: Field?

    private enum Field {
        case name, link
    }

    /// Of the body card.
    static let size = CGSize(width: 820, height: 410)

    var body: some View {
        CommandScreen(
            icon: .symbol("link", tint: .purple),
            path: ["Quicklinks", draft.isNew ? "New Quicklink" : "Edit Quicklink"],
            size: Self.size
        ) {
            CapsuleButton(title: draft.isNew ? "Add" : "Save", keys: ["⌘", "↵"], isProminent: true) {
                model.saveQuicklink()
            }
        } content: {
            HStack(spacing: 0) {
                form
                    .padding(.leading, 24)
                    .padding(.trailing, 14)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                SidePanel {
                    assistant
                }
            }
        }
        .onAppear { focus = draft.isNew ? .name : .link }
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelLabel("Name")
            TextField("Name", text: $draft.name, prompt: Text(verbatim: "Search Wikipedia"))
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .bold))
                .focused($focus, equals: .name)
                .padding(.top, 3)

            PanelLabel("Link")
                .padding(.top, 18)
            TextField("Link", text: $draft.link, prompt: Text(verbatim: QuicklinkDraft.linkExample), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...5)
                .font(.system(size: 13, design: .monospaced))
                .focused($focus, equals: .link)
                .modifier(FieldBox(isFocused: focus == .link))
                .padding(.top, 7)
            Text("A website, a folder or a link into an app.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 7)

            FormGroup {
                FormRow(title: "Open with") {
                    applicationMenu
                }
            }
            .padding(.top, 18)
        }
    }

    private var applicationMenu: some View {
        Menu {
            Picker("Open with", selection: $draft.openWith) {
                Text("Default App").tag(String?.none)
                let apps = draft.applications
                if !apps.isEmpty {
                    Divider()
                    ForEach(apps, id: \.bundleID) { app in
                        Text(app.name).tag(String?.some(app.bundleID))
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            let app = draft.openingApplication
            let name = app.map { FileManager.default.displayName(atPath: $0.path) }
            PopupLabel(title: draft.openWith == nil ? name.map { "Default (\($0))" } ?? "Default App" : name ?? "Unknown App") {
                if let app {
                    IconView(icon: .file(path: app.path), size: 18)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Side panel

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelLabel("Insert")
            FlowLayout(spacing: 6) {
                ForEach(QuicklinkDraft.placeholders, id: \.title) { placeholder in
                    Chip(title: placeholder.title) {
                        draft.link += placeholder.text
                        focus = .link
                    }
                }
            }
            .padding(.top, 9)
            Text("Placeholders are filled in when the link opens. Arguments are asked for in the search bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            PanelDivider()
                .padding(.vertical, 14)

            PanelLabel("Preview")
            preview
                .padding(.top, 9)
        }
    }

    /// How the quicklink shows up in the search bar, and the link it opens.
    @ViewBuilder private var preview: some View {
        let template = LinkTemplate(draft.link)
        let name = draft.name.trimmingCharacters(in: .whitespaces)

        HStack(spacing: 8) {
            IconView(icon: QuicklinkModule.icon(for: template), size: 22, loadsFavicon: false)
            Text(name.isEmpty ? "Name" : name)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            ForEach(Array(template.arguments.enumerated()), id: \.offset) { _, argument in
                Text(argument.defaultValue ?? argument.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Theme.fieldFill, in: Capsule())
                    .overlay { Capsule().strokeBorder(Theme.fieldStroke) }
            }
        }

        let example = template.resolve(LinkTemplate.Values(
            arguments: template.arguments.map(\.name),
            clipboard: "clipboard",
            selection: "selection"
        ))
        if example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("The link it opens appears here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        } else {
            PreviewBox(text: example)
                .lineLimit(4)
                .padding(.top, 10)
        }
    }
}
