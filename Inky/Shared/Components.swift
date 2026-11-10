import AppKit
import InkyCore
import SwiftUI

/// Draws an `Icon`: a Finder icon, or a symbol on a tinted tile.
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 24

    var body: some View {
        switch icon {
        case .file(let path):
            Image(nsImage: IconCache.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        case .symbol(let name, let tint):
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(tint.color.gradient)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: name)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
        }
    }
}

final class IconCache {
    static let shared = IconCache()

    private let cache = NSCache<NSString, NSImage>()

    func icon(forFile path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

extension Tint {
    var color: Color {
        switch self {
        case .gray: .gray
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        }
    }
}

/// A row of keyboard keys, such as ⌘ K.
struct Keycaps: View {
    let keys: [String]

    init(_ keys: [String]) {
        self.keys = keys
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }
}
