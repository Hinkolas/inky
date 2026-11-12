import AppKit
import InkyCore
import Observation
import SwiftUI

/// A quicklink being created or edited.
@Observable
final class QuicklinkDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var name: String
    var link: String
    var openWith: String?

    init(_ quicklink: Quicklink? = nil) {
        id = quicklink?.id ?? UUID()
        isNew = quicklink == nil
        name = quicklink?.name ?? ""
        link = quicklink?.link ?? ""
        openWith = quicklink?.openWith
    }

    /// A new quicklink to `link`, with only its name left to type.
    convenience init(link: String) {
        self.init()
        self.link = link
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !link.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var quicklink: Quicklink {
        Quicklink(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            link: link.trimmingCharacters(in: .whitespacesAndNewlines),
            openWith: openWith
        )
    }

    static let linkExample = "https://example.com/search?q={argument name=\"Query\"}"

    static let placeholders: [(title: String, text: String)] = [
        ("Argument", "{argument name=\"Query\"}"),
        ("Clipboard Text", "{clipboard}"),
        ("Selected Text", "{selection}"),
        ("Date", "{date}"),
        ("UUID", "{uuid}"),
    ]

    /// A URL of the same kind as the link, to ask the system what opens it.
    private var sampleURL: URL? {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        } else if let scheme = trimmed.firstMatch(of: /^([A-Za-z][A-Za-z0-9+.-]*):/)?.1 {
            return URL(string: "\(scheme)://example.com")
        }
        return URL(string: "https://example.com")
    }

    /// The apps that can open this kind of link.
    var applications: [(bundleID: String, name: String)] {
        var apps = (sampleURL.map(NSWorkspace.shared.urlsForApplications(toOpen:)) ?? []).compactMap { url -> (bundleID: String, name: String)? in
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
            return (bundleID, FileManager.default.displayName(atPath: url.path))
        }
        // Keep showing a saved choice even if it no longer claims the link type.
        if let openWith, !apps.contains(where: { $0.bundleID == openWith }) {
            apps.append((openWith, Self.applicationName(openWith)))
        }
        return apps
    }

    /// The app the link opens in: the chosen one, or the system's default.
    var openingApplication: URL? {
        if let openWith {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: openWith)
        }
        return sampleURL.flatMap(NSWorkspace.shared.urlForApplication(toOpen:))
    }

    static func applicationName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}

/// The fields of a quicklink, as a standard form. Used in settings.
struct QuicklinkForm: View {
    @Bindable var draft: QuicklinkDraft
    @FocusState private var focus: Field?

    private enum Field {
        case name, link
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 18) {
            GridRow {
                label("Name")
                TextField("Name", text: $draft.name, prompt: Text(verbatim: "Search Wikipedia"))
                    .focused($focus, equals: .name)
                    .modifier(FieldStyle(isFocused: focus == .name))
            }
            GridRow {
                label("Link")
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Link", text: $draft.link, prompt: Text(verbatim: QuicklinkDraft.linkExample), axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focus, equals: .link)
                        .modifier(FieldStyle(isFocused: focus == .link))

                    HStack(spacing: 6) {
                        Text("A website, folder or app link. Placeholders are filled in when it opens.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Menu("Insert") {
                            ForEach(QuicklinkDraft.placeholders, id: \.title) { placeholder in
                                Button(placeholder.title) { draft.link += placeholder.text }
                            }
                        }
                        .fixedSize()
                    }
                    .font(.system(size: 12))
                }
            }
            GridRow {
                label("Open With")
                Picker("Open With", selection: $draft.openWith) {
                    Text("Default App").tag(String?.none)
                    let apps = draft.applications
                    if !apps.isEmpty {
                        Divider()
                        ForEach(apps, id: \.bundleID) { app in
                            Text(app.name).tag(String?.some(app.bundleID))
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .onAppear { focus = draft.isNew ? .name : .link }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

private struct FieldStyle: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.15)))
            }
    }
}
