import AppKit
import CoreImage
import FaviconFinder
import SwiftUI

/// One resolved favicon: the 64 px render for display, plus the bytes it came from so
/// the on-disk copy keeps the site's full resolution.
struct FaviconPayload {
    let image: NSImage
    let data: Data
    let sourceURL: URL
    let pixels: CGFloat
}

final class FaviconService: ObservableObject {
    static let shared = FaviconService()
    private var cache: [String: NSImage] = [:]
    private var colorCache: [String: Color] = [:]
    private var sourceURLCache: [String: URL] = [:]
    private var isFetching: Set<String> = []
    private var pendingCompletions: [String: [(NSImage?) -> Void]] = [:]
    /// Original downloaded bytes, kept so a second tab on the same domain writes the real
    /// icon file rather than a TIFF snapshot of the already-downscaled image.
    private let originalBytes = NSCache<NSString, NSData>()
    /// Decoded 64 px icons keyed by on-disk path, shared by every row showing that file.
    private let fileImages = NSCache<NSString, NSImage>()
    /// Never download more than this many candidates before settling for the best so far.
    private static let maxCandidateDownloads = 3
    // Negative cache: without it, every SwiftUI render of a domain with no
    // resolvable favicon kicks off another full network fetch.
    private var failedFetches: [String: Date] = [:]
    private let failureRetryInterval: TimeInterval = 300

    func getFavicon(for searchURL: String) -> NSImage? {
        guard let domain = extractDomain(from: searchURL) else { return nil }

        if let cachedFavicon = cache[domain] {
            return cachedFavicon
        }

        fetchAndCacheFavicon(for: domain)
        return nil
    }

    func getFaviconColor(for searchURL: String) -> Color? {
        guard let domain = extractDomain(from: searchURL) else { return nil }

        if let cachedColor = colorCache[domain] {
            return cachedColor
        }

        // If favicon exists but color doesn't, compute it
        if let favicon = cache[domain] {
            let color = Color(favicon.averageColor())
            colorCache[domain] = color
            return color
        }

        fetchAndCacheFavicon(for: domain)
        return nil
    }

    func faviconURL(for domain: String) -> URL? {
        let normalizedDomain = normalizeDomain(domain)
        return sourceURLCache[normalizedDomain] ?? canonicalURL(for: normalizedDomain)
    }

    func faviconURL(forSearchURL searchURL: String) -> URL? {
        guard let domain = extractDomain(from: searchURL) else { return nil }
        return canonicalURL(for: domain)
    }

    private func extractDomain(from searchURL: String) -> String? {
        let trimmed = searchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sanitized = trimmed.replacingOccurrences(of: "{query}", with: "")

        if let host = URL(string: sanitized)?.host {
            return normalizeDomain(host)
        }

        if let host = URL(string: "https://\(sanitized)")?.host {
            return normalizeDomain(host)
        }

        return nil
    }

    private func normalizeDomain(_ domain: String) -> String {
        let lowercased = domain.lowercased()
        return lowercased.hasPrefix("www.") ? String(lowercased.dropFirst(4)) : lowercased
    }

    private func canonicalURL(for domain: String) -> URL? {
        guard !domain.isEmpty else { return nil }
        return URL(string: "https://\(domain)")
    }

    func fetchFaviconSync(for searchURL: String, completion: @escaping (NSImage?) -> Void) {
        guard let domain = extractDomain(from: searchURL) else {
            completion(nil)
            return
        }
        if let cachedFavicon = cache[domain] {
            completion(cachedFavicon)
            return
        }
        fetchAndCacheFavicon(for: domain, completion: completion)
    }

    private func fetchAndCacheFavicon(for domain: String, completion: ((NSImage?) -> Void)? = nil) {
        if let cachedFavicon = cache[domain] {
            completion?(cachedFavicon)
            return
        }

        if let failedAt = failedFetches[domain], Date().timeIntervalSince(failedAt) < failureRetryInterval {
            completion?(nil)
            return
        }

        if let completion {
            pendingCompletions[domain, default: []].append(completion)
        }

        guard !isFetching.contains(domain) else { return }
        isFetching.insert(domain)

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let payload = await self.fetchFaviconPayload(for: domain)
            await MainActor.run {
                self.completeFetch(
                    for: domain,
                    favicon: payload?.image,
                    sourceURL: payload?.sourceURL,
                    data: payload?.data
                )
            }
        }
    }

    @MainActor
    private func completeFetch(for domain: String, favicon: NSImage?, sourceURL: URL?, data: Data? = nil) {
        if let favicon {
            cache[domain] = favicon
            if let data { originalBytes.setObject(data as NSData, forKey: domain as NSString) }
            colorCache[domain] = Color(favicon.averageColor())
            if let sourceURL {
                sourceURLCache[domain] = sourceURL
            }
            failedFetches.removeValue(forKey: domain)
            objectWillChange.send()
        } else {
            failedFetches[domain] = Date()
        }

        isFetching.remove(domain)
        let completions = pendingCompletions.removeValue(forKey: domain) ?? []
        for completion in completions {
            completion(favicon)
        }
    }

    /// Loads a stored favicon file and decodes it once, at 64 px, for every row that
    /// shows it. Safe to call off the main thread.
    func icon(atFile fileURL: URL) -> NSImage? {
        let key = fileURL.path as NSString
        if let cached = fileImages.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: fileURL),
              let image = FaviconDecoder.decode(data)
        else { return nil }
        fileImages.setObject(image, forKey: key)
        return image
    }

    /// Walks the ranked candidates, stopping at the first one that is genuinely ≥ 32 px
    /// and otherwise keeping the largest that did download.
    private func fetchFaviconPayload(for domain: String) async -> FaviconPayload? {
        guard let siteURL = canonicalURL(for: domain) else { return nil }

        let declared = (try? await FaviconFinder(url: siteURL).fetchFaviconURLs()) ?? []
        var candidates = FaviconCandidates.ranked(declared)
        // Every declared icon was a share card, so the root .ico is the only hope left.
        if candidates.isEmpty, let rootICO = URL(string: "https://\(domain)/favicon.ico") {
            candidates = [FaviconURL(source: rootICO, format: .ico, sourceType: .ico)]
        }

        var best: FaviconPayload?
        for candidate in candidates.prefix(Self.maxCandidateDownloads) {
            guard let favicon = try? await candidate.download(),
                  let downloaded = favicon.image
            else { continue }

            let pixels = FaviconDecoder.nativeDimension(of: downloaded.image)
            guard let decoded = FaviconDecoder.decode(downloaded.data) else { continue }
            if pixels > (best?.pixels ?? 0) {
                best = FaviconPayload(
                    image: decoded,
                    data: downloaded.data,
                    sourceURL: favicon.url.source,
                    pixels: pixels
                )
            }
            if pixels >= FaviconCandidates.minimumPixels { break }
        }

        return best
    }

    func downloadAndSaveFavicon(
        for domain: String,
        faviconURL _: URL,
        to saveURL: URL,
        completion: @escaping (URL?, Bool) -> Void
    ) {
        let normalizedDomain = normalizeDomain(domain)
        // The original bytes, never a re-encode of the downscaled render: writing
        // `tiffRepresentation` here is what used to bake 16 px icons onto disk.
        if let data = originalBytes.object(forKey: normalizedDomain as NSString) {
            do {
                try (data as Data).write(to: saveURL, options: .atomic)
                completion(faviconURL(for: normalizedDomain), true)
            } catch {
                completion(nil, false)
            }
            return
        }

        Task(priority: .utility) { [weak self] in
            guard let self else {
                completion(nil, false)
                return
            }

            let payload = await self.fetchFaviconPayload(for: normalizedDomain)
            await MainActor.run {
                guard let payload else {
                    completion(nil, false)
                    return
                }

                self.completeFetch(
                    for: normalizedDomain,
                    favicon: payload.image,
                    sourceURL: payload.sourceURL,
                    data: payload.data
                )

                do {
                    try payload.data.write(to: saveURL, options: .atomic)
                    completion(payload.sourceURL, true)
                } catch {
                    completion(nil, false)
                }
            }
        }
    }
}

extension NSImage {
    func averageColor() -> NSColor {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return NSColor.gray
        }

        let inputImage = CIImage(cgImage: cgImage)
        let extentVector = CIVector(
            x: inputImage.extent.origin.x,
            y: inputImage.extent.origin.y,
            z: inputImage.extent.size.width,
            w: inputImage.extent.size.height
        )

        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]
        ) else {
            return NSColor.gray
        }

        guard let outputImage = filter.outputImage else {
            return NSColor.gray
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return NSColor(
            red: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: CGFloat(bitmap[3]) / 255
        )
    }
}
