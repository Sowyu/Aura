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

    // MARK: - Navigation

    /// The request a hard reload sends: this page's own address, fetched without
    /// consulting the local cache.
    ///
    /// Not `reloadFromOrigin()`, which revalidates: a server answering 304 there hands
    /// back the bytes already in the cache, and bypassing exactly that is why the user
    /// pressed the key.
    static func hardReloadRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// Reloads the current page with the cache bypassed (⇧⌘R). A page that has not
    /// committed an address yet has nothing to re-request, so it falls back to the
    /// plain reload.
    func hardReload() {
        guard let url = currentURL ?? lastCommittedURL else {
            reload()
            return
        }
        load(Self.hardReloadRequest(for: url))
    }

    /// The entry `offset` pages away in the back/forward list, negative for back. Nil
    /// once the offset runs off either end, which is what a stale menu row looks like.
    func backForwardItem(atOffset offset: Int) -> WKBackForwardListItem? {
        auraWebView.backForwardList.item(at: offset)
    }

    /// Travels to an entry the back/forward menu picked. WebKit keeps the page's own
    /// scroll position and form state for it, which re-loading its address would not.
    func go(to item: WKBackForwardListItem) {
        auraWebView.go(to: item)
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
    /// A web archive carries the page's subresources inside it, so the saved file opens
    /// offline, which a bare HTML dump does not.
    func saveWebArchive(named name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("com.apple.webarchive")].compactMap { $0 }
        panel.nameFieldStringValue = "\(Self.safeFileName(name)).webarchive"
        panel.canCreateDirectories = true

        present(panel) { [weak self] destination in
            self?.auraWebView.createWebArchiveData { result in
                guard case let .success(data) = result else { return }
                try? data.write(to: destination)
            }
        }
    }

    /// Downloads `url` through WebKit, so cookies and the space's data store apply, and
    /// hands the result to the same delegate path a navigation download takes.
    ///
    /// The page's own address rides along as `Referer`: hotlink-protected image and file
    /// hosts answer a bare request with a placeholder or a 403, and a download started
    /// from the context menu is exactly the case they are guarding against.
    func startDownload(from url: URL) {
        auraWebView.startDownload(using: pageRequest(for: url)) { [weak self] download in
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

    // MARK: - Page capture

    /// The document as the user is looking at it, scripts and all, rather than the
    /// markup the server sent. That is the whole point of taking it from the live page:
    /// most of a modern page's content does not exist until its scripts have run.
    func captureDocumentHTML(completion: @escaping (String?) -> Void) {
        evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
            completion(value as? String)
        }
    }

    /// Full-page screenshot, rendered through `createPDF`.
    ///
    /// `takeSnapshot` used to be tried first for the sharper bitmap, scoped to the
    /// document rect. Two things were wrong with that. A rect-scoped snapshot is a known
    /// WebKit flash trigger (see `BrowserSnapshotConfiguration`), and the rect is in view
    /// coordinates, so a scrolled page captured from the scroll offset down and lost
    /// everything above it. `createPDF` lays the whole document out at the rect it is
    /// given, the way printing does, so it starts at the top whatever the page is
    /// showing.
    func captureFullPageImage(completion: @escaping (NSImage?) -> Void) {
        let measure = "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]"
        evaluateJavaScript(measure) { [weak self] value, _ in
            guard let self else {
                completion(nil)
                return
            }
            let numbers = (value as? [NSNumber])?.map(\.doubleValue) ?? []
            guard numbers.count == 2, numbers[0] > 1, numbers[1] > 1 else {
                self.snapshotViewport(completion: completion)
                return
            }
            let size = CGSize(
                width: min(numbers[0], Self.maxCaptureEdge),
                height: min(numbers[1], Self.maxCaptureEdge)
            )
            self.renderPDFImage(size: size, completion: completion)
        }
    }

    /// A page taller than this renders to hundreds of megabytes of bitmap, and no one
    /// reads a screenshot that long.
    /// ponytail: hard cap, raise it if someone actually needs a taller capture.
    private static let maxCaptureEdge: Double = 12_000

    /// Past this height a 2x bitmap costs more memory than the extra sharpness is worth.
    private static let retinaCaptureLimit: CGFloat = 6_000

    private func snapshotViewport(completion: @escaping (NSImage?) -> Void) {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        auraWebView.takeSnapshot(with: configuration) { image, _ in completion(image) }
    }

    /// The vector page is rasterised here, because the caller writes a PNG.
    private func renderPDFImage(size: CGSize, completion: @escaping (NSImage?) -> Void) {
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        auraWebView.createPDF(configuration: configuration) { result in
            guard case let .success(data) = result, let page = NSImage(data: data) else {
                completion(nil)
                return
            }
            completion(Self.rasterise(page))
        }
    }

    /// Draws a PDF-backed image into a bitmap at 2x on an opaque white ground. A PDF
    /// page has no background of its own, and a transparent PNG of black text is
    /// unreadable in every viewer that composites it on dark.
    private static func rasterise(_ image: NSImage) -> NSImage? {
        let points = image.size
        guard points.width > 0, points.height > 0 else { return nil }
        let scale: CGFloat = points.height > retinaCaptureLimit ? 1 : 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(points.width * scale),
            pixelsHigh: Int(points.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = points
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(origin: .zero, size: points)
        NSColor.white.setFill()
        bounds.fill()
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        let output = NSImage(size: points)
        output.addRepresentation(rep)
        return output
    }

    /// Writes a full-page screenshot to a file the user picks. `name` seeds the file name.
    func saveFullPageScreenshot(named name: String) {
        captureFullPageImage { [weak self] image in
            guard let self, let image, let data = Self.pngData(from: image) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(Self.safeFileName(name)).png"
            panel.canCreateDirectories = true
            self.present(panel) { destination in
                try? data.write(to: destination)
            }
        }
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Images

    /// Fetches an image the way the page itself would: the page's address as `Referer`,
    /// the space's own cookies, and the web view's user agent.
    ///
    /// WebKit exposes no way to read a decoded image straight out of a page, so the bytes
    /// are fetched a second time here. `data:` sources never leave the process: they carry
    /// their own bytes and a URL session cannot be relied on to hand them back.
    func fetchImageData(at url: URL, completion: @escaping (Data?) -> Void) {
        if url.scheme?.lowercased() == "data" {
            completion(Self.decodeDataURL(url))
            return
        }
        var request = pageRequest(for: url)
        // The space's cookies are attached by hand below; left on, the URL loading system
        // overwrites that header with whatever the process-wide jar holds.
        request.httpShouldHandleCookies = false
        auraWebView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            var authorised = request
            let header = HTTPCookie.requestHeaderFields(with: cookies.filter { $0.matches(url) })
            for (field, value) in header {
                authorised.setValue(value, forHTTPHeaderField: field)
            }
            Self.imageSession.dataTask(with: authorised) { data, _, _ in
                completion(data)
            }.resume()
        }
    }

    /// Ephemeral and cookie-blind: `URLSession.shared` writes the response into the
    /// shared on-disk cache and any `Set-Cookie` into the process jar, which puts a
    /// private tab's image fetch on disk. Built once, because a session per fetch leaks
    /// its own connection pool.
    private static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Puts the image on the pasteboard as an image, so it pastes into Mail and Preview
    /// rather than as a link.
    func copyImage(at url: URL) {
        fetchImageData(at: url) { data in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
    }

    /// The bytes of a `data:` URL. Only base64 payloads are decoded; a percent-encoded
    /// one is rare enough on an image that reading it back as UTF-8 is honest.
    static func decodeDataURL(_ url: URL) -> Data? {
        let raw = url.absoluteString
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        let meta = raw[raw.startIndex ..< comma]
        let payload = String(raw[raw.index(after: comma)...])
        if meta.lowercased().hasSuffix(";base64") {
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    // MARK: - Shared plumbing

    /// A request that looks like it came from the page, which is what hotlink and CSRF
    /// guards check.
    private func pageRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let referrer = currentURL ?? lastCommittedURL, referrer.scheme?.hasPrefix("http") == true {
            request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let agent = auraWebView.customUserAgent, !agent.isEmpty {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    /// Runs a save panel as a sheet on the page's own window, or modally when it has none.
    private func present(_ panel: NSSavePanel, completion: @escaping (URL) -> Void) {
        if let window = auraWebView.window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                completion(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    /// Path separators and colons in a page title make an unopenable file name.
    static func safeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
        let capped = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? "page" : capped
    }
}

private extension HTTPCookie {
    /// Domain and path match, the way a browser decides which cookies to send.
    func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let cookieDomain = domain.lowercased()
        let domainMatches = cookieDomain.hasPrefix(".")
            ? host == String(cookieDomain.dropFirst()) || host.hasSuffix(cookieDomain)
            : host == cookieDomain
        guard domainMatches else { return false }
        if isSecure, url.scheme?.lowercased() != "https" { return false }
        let cookiePath = path.isEmpty ? "/" : path
        return url.path.hasPrefix(cookiePath) || cookiePath == "/"
    }
}

