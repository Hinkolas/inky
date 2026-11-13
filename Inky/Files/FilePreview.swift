import AppKit
import InkyCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// What the side panel shows of a file.
enum FilePreview {
    /// The beginning of what it says.
    case text(String)
    /// A picture of it, as Quick Look draws one.
    case image(NSImage)
    /// The names of the first things in a folder, and how many there are.
    case folder(names: [String], total: Int)
    /// Nothing of its own: its icon stands for it.
    case icon

    /// What a run prints of it.
    var debugName: String {
        switch self {
        case .text(let text): "text(\(text.count))"
        case .image(let image): "image(\(Int(image.size.width))x\(Int(image.size.height)))"
        case .folder(_, let total): "folder(\(total))"
        case .icon: "icon"
        }
    }
}

/// Reads what a file is previewed by, away from the main thread.
///
/// This is the only place the file search reads a file itself. In Desktop,
/// Documents and Downloads, macOS asks the user once whether Inky may.
/// Refused, such a file is shown by its icon.
nonisolated enum FilePreviewLoader {
    /// What was read, in a form that can be handed to the main thread.
    enum Content: Sendable {
        case text(String)
        case image(CGImage)
        case folder(names: [String], total: Int)
        case icon
    }

    /// How many names of a folder are kept. More than the panel has room for.
    private static let folderLimit = 40

    /// - Parameter size: The room there is for a picture, in points.
    @concurrent static func load(_ file: FileHit, size: CGSize, scale: CGFloat) async -> Content {
        if file.isFolder {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: file.path) else { return .icon }
            let visible = names
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return .folder(names: Array(visible.prefix(folderLimit)), total: visible.count)
        }

        let type = file.contentType.flatMap { UTType($0) }
        if !isDrawn(type), let text = excerpt(of: file.path) {
            return .text(text)
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: file.path),
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return .image(thumbnail.cgImage)
        }
        return .icon
    }

    /// Whether a file of this type is shown by a picture without looking for
    /// text in it first. Everything else is read: much of what is text does
    /// not say so by its type, such as a Makefile.
    private static func isDrawn(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return [UTType.image, .audiovisualContent, .pdf, .rtf, .archive].contains(where: type.conforms(to:))
    }

    private static func excerpt(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: FileExcerpt.byteLimit) else { return nil }
        return FileExcerpt.text(from: data)
    }
}

extension FilePreview {
    init(_ content: FilePreviewLoader.Content, scale: CGFloat) {
        self = switch content {
        case .text(let text): .text(text)
        case .image(let image):
            .image(NSImage(
                cgImage: image,
                size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            ))
        case .folder(let names, let total): .folder(names: names, total: total)
        case .icon: .icon
        }
    }
}

/// The selected file, as much of it as there is room for. It fills the room
/// it is given, whatever it shows, so that nothing around it moves.
struct FilePreviewView: View {
    let file: FileHit
    /// Nil until it is read.
    let preview: FilePreview?

    private static let entryHeight: CGFloat = 27

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            switch preview {
            case .text(let text):
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(11)
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // A small picture stays small instead of being blown up.
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(9)
            case .folder(let names, let total):
                if names.isEmpty {
                    Text("Empty folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    GeometryReader { geometry in
                        entries(names, total: total, rows: Int((geometry.size.height - 14) / Self.entryHeight))
                    }
                }
            case .icon:
                IconView(icon: .file(path: file.path), size: 96)
            case nil:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.fieldFill, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.fieldStroke) }
    }

    /// As many of a folder's names as there are rows for. If there are more,
    /// the last row says how many.
    private func entries(_ names: [String], total: Int, rows: Int) -> some View {
        let shown = total > rows ? max(rows - 1, 0) : total
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(names.prefix(shown), id: \.self) { name in
                HStack(spacing: 9) {
                    IconView(icon: .file(path: (file.path as NSString).appendingPathComponent(name)), size: 17)
                    Text(name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(height: Self.entryHeight)
            }
            if total > shown {
                Text("and \((total - shown).formatted()) more")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .frame(height: Self.entryHeight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// How a file is put into words.
enum FileDescription {
    /// What the side panel says about a file. `preview` tells how much is in
    /// a folder, once it is read.
    static func facts(about file: FileHit, preview: FilePreview?) -> [(name: String, value: String)] {
        var facts: [(name: String, value: String)] = [
            ("Where", file.folder),
            ("Kind", file.kind ?? (file.isFolder ? "Folder" : "File")),
        ]
        if file.isFolder {
            // A space until it is read, so that nothing moves when it is.
            let contents: String = switch preview {
            case .folder(_, let total): total == 1 ? "1 item" : "\(total.formatted()) items"
            case nil: " "
            default: "Not known"
            }
            facts.append(("Contains", contents))
        } else if let size = file.size {
            facts.append(("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        if let width = file.pixelWidth, let height = file.pixelHeight, width > 0, height > 0 {
            facts.append(("Pixels", "\(width) × \(height)"))
        }
        if let duration = file.duration, duration > 0 {
            facts.append(("Duration", Duration.seconds(duration.rounded()).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))))
        }
        if let pages = file.pages, pages > 0 {
            facts.append(("Pages", pages.formatted()))
        }
        if let created = file.created {
            facts.append(("Created", date.string(from: created)))
        }
        if let modified = file.modified {
            facts.append(("Modified", date.string(from: modified)))
        }
        if let lastOpened = file.lastOpened {
            facts.append(("Last opened", date.string(from: lastOpened)))
        }
        return facts
    }

    /// "Today at 14:31", and a date for what is older than yesterday.
    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}
