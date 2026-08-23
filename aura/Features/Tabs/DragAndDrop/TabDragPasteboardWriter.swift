import AppKit
import Foundation

extension NSPasteboard.PasteboardType {
    /// The name a receiver shows for a dragged address. AppKit declares no constant for
    /// it, only for `public.url`.
    static let auraURLName = NSPasteboard.PasteboardType("public.url-name")
}

/// A `.webloc` file: the plist Finder reads to make an internet-location link. One key,
/// documented nowhere official, stable since Mac OS X 10.0.
enum WeblocFile {
    static let contentType = "com.apple.web-internet-location"

    static func data(for url: URL) -> Data? {
        try? PropertyListSerialization.data(
            fromPropertyList: ["URL": url.absoluteString],
            format: .xml,
            options: 0
        )
    }
}

/// What a sidebar row puts on the pasteboard when it is dragged.
///
/// Inside Aura only `.auraTabItem` matters, and the drop resolver reads nothing else, so
/// the intra-app drag is unchanged. The rest is for everyone outside: `public.url` is
/// what a browser or a text field takes, and the file promise is what Finder needs to
/// write a link file into a folder, since a pasteboard URL alone gives it no name and no
/// bytes to create one with.
final class TabDragPasteboardWriter: NSFilePromiseProvider {
    private let tabID: UUID
    private let url: URL
    private let title: String

    /// `NSFilePromiseProvider.delegate` is weak and nothing else would own this one, so
    /// the provider holds it. The delegate does not point back, so there is no cycle.
    private let promiseDelegate: TabWeblocPromiseDelegate

    init(tabID: UUID, url: URL, title: String) {
        self.tabID = tabID
        self.url = url
        self.title = title
        let delegate = TabWeblocPromiseDelegate(url: url, title: title)
        promiseDelegate = delegate
        super.init()
        fileType = WeblocFile.contentType
        self.delegate = delegate
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.auraTabItem, .URL, .auraURLName, .string]
    }

    /// Only the promise is promised. Left to the superclass, the types added above would
    /// be marked promised too and every reader would get nothing for them.
    override func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        guard super.writableTypes(for: pasteboard).contains(type) else { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .auraTabItem:
            return tabID.uuidString
        case .URL, .string:
            return url.absoluteString
        case .auraURLName:
            return title
        default:
            return super.pasteboardPropertyList(forType: type)
        }
    }
}

/// Writes the promised `.webloc` once the drop lands.
final class TabWeblocPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let url: URL
    private let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        let seed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = BrowserPage.safeFileName(seed.isEmpty ? (url.host ?? "link") : seed)
        return "\(name).webloc"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo destination: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let data = WeblocFile.data(for: url) else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        do {
            try data.write(to: destination)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
