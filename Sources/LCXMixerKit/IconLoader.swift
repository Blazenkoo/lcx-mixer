import AppKit

/// Decodes and caches tab favicons. The extension sends them as data URLs from Chrome's
/// local favicon cache, so the app itself makes no network requests.
@MainActor
final class IconLoader {
    private var cache: [String: NSImage] = [:]

    func icon(for urlString: String, completion: @escaping @MainActor (NSImage) -> Void) -> NSImage? {
        guard urlString.hasPrefix("data:") else { return nil }
        if let image = cache[urlString] { return image }
        guard let url = URL(string: urlString),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[urlString] = image
        return image
    }
}
