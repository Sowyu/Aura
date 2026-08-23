import Foundation

/// Comparing two web-extension version strings.
///
/// Manifest versions are dotted numbers ("1.62.0", "2026.820.1159"), which is what
/// Chrome's format allows and what AMO reports back. Firefox's own comparator
/// understands suffixes like "1.0b2"; Aura only has to answer "is this one later", so
/// each component compares as a number first and as text only to break a numeric tie.
enum ExtensionVersion {
    /// True when `candidate` is later than `installed`. Equal versions, an unparsable
    /// pair, or a downgrade all answer false: offering an update that is not one is
    /// worse than missing one.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let left = components(of: candidate)
        let right = components(of: installed)
        for index in 0 ..< max(left.count, right.count) {
            let mine = index < left.count ? left[index] : (number: 0, suffix: "")
            let theirs = index < right.count ? right[index] : (number: 0, suffix: "")
            if mine.number != theirs.number {
                return mine.number > theirs.number
            }
            if mine.suffix != theirs.suffix {
                return mine.suffix > theirs.suffix
            }
        }
        return false
    }

    /// One dotted component split into its leading number and whatever trails it, so
    /// "10" sorts after "9" rather than before it.
    private static func components(of version: String) -> [(number: Int, suffix: String)] {
        version.split(separator: ".").map { part in
            let digits = part.prefix { $0.isNumber }
            return (Int(digits) ?? 0, String(part.dropFirst(digits.count)))
        }
    }
}

/// The AMO version check for installed add-ons.
///
/// Only extensions carrying a gecko id can be checked: that id is what AMO knows a
/// listing by, and an add-on installed from a folder or a .crx has no listing to
/// compare against. The fetch is injected so the check is testable without the
/// network, and every failure is per-extension: AMO being unreachable means no
/// updates were found, never an error in the user's face.
enum ExtensionUpdates {
    typealias Fetch = (String) async throws -> FirefoxAddon

    /// How long an answer is good for. Extensions do not ship hourly, and a browser
    /// that talks to AMO on every launch is a browser that talks to AMO too much.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    static func isDue(lastCheck: Date?, now: Date = Date(), force: Bool = false) -> Bool {
        if force {
            return true
        }
        guard let lastCheck else { return true }
        // A clock that moved backwards (timezone edit, restore) would otherwise park
        // the check until the original date came round again.
        return now.timeIntervalSince(lastCheck) >= checkInterval || now < lastCheck
    }

    /// Newer versions by extension id. Entries with no gecko id, no version, or
    /// nothing newer on AMO are simply absent.
    static func check(_ installed: [InstalledExtension], fetch: Fetch) async -> [String: String] {
        var found: [String: String] = [:]
        for entry in installed {
            guard !Task.isCancelled else { break }
            guard let geckoID = entry.geckoID, let current = entry.displayVersion else { continue }
            guard let addon = try? await fetch(geckoID), let latest = addon.version else { continue }
            guard ExtensionVersion.isNewer(latest, than: current) else { continue }
            found[entry.id] = latest
        }
        return found
    }
}
