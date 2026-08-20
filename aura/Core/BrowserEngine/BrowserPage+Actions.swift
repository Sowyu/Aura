import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Page-level commands the chrome and the page context menu both reach for, plus the
/// bridge that feeds the context menu what sits under the pointer.
extension BrowserPage {
    func installContextMenuBridge() {
        auraWebView.onContextMenu = { [weak self] location, inspect in
            guard let self else { return }
            self.delegate?.browserPage(
                self,
                didRequestContextMenu: self.lastContextMenuInfo,
                at: location,
                inspectElement: inspect
            )
        }
    }

    /// Prints the current page, sheeted on its own window when it has one.
    func printPage() {
        let operation = auraWebView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = auraWebView.bounds
        if let window = auraWebView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// Writes the page to a `.webarchive` the user picks. `name` seeds the file name.
    func saveWebArchive(named name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("com.apple.webarchive")].compactMap { $0 }
        panel.nameFieldStringValue = "\(name).webarchive"
        panel.canCreateDirectories = true

        let complete: (URL) -> Void = { [weak self] destination in
            self?.auraWebView.createWebArchiveData { result in
                guard case let .success(data) = result else { return }
                try? data.write(to: destination)
            }
        }

        if let window = auraWebView.window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                complete(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            complete(url)
        }
    }

    /// Downloads `url` through WebKit, so cookies and the space's data store apply, and
    /// hands the result to the same delegate path a navigation download takes.
    func startDownload(from url: URL) {
        auraWebView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { return }
            self.delegate?.browserPage(self, didStartDownload: BrowserDownloadTask(
                download: download,
                originalURL: url
            ))
        }
    }

    func cacheContextMenuInfo(_ body: Any) {
        guard let payload = body as? [String: Any] else { return }
        func url(_ key: String) -> URL? {
            guard let raw = payload[key] as? String, !raw.isEmpty else { return nil }
            return URL(string: raw)
        }
        func text(_ key: String) -> String? {
            guard let raw = payload[key] as? String, !raw.isEmpty else { return nil }
            return raw
        }
        lastContextMenuInfo = BrowserContextMenuInfo(
            link: url("link"),
            linkText: text("linkText"),
            image: url("image"),
            media: url("media"),
            selection: text("selection"),
            isEditable: payload["isEditable"] as? Bool ?? false
        )
    }

}
