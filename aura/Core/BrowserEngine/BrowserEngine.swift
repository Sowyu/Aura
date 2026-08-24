import Foundation
import WebKit

struct BrowserPageConfiguration {
    let userAgent: String?
    let allowsPictureInPicture: Bool
    let allowsJavaScript: Bool
    let allowsJavaScriptWindowsAutomatically: Bool
    let allowsAirPlayForMediaPlayback: Bool
    let allowsInspectableDebugging: Bool
    let allowsBackForwardNavigationGestures: Bool
    let mediaPlaybackRequiresUserAction: Bool
    let scriptMessageNames: [String]
    let userScripts: [BrowserUserScript]
    let privacySettings: SpacePrivacySettings

    static func oraDefault(
        userScripts: [BrowserUserScript],
        privacySettings: SpacePrivacySettings
    ) -> BrowserPageConfiguration {
        BrowserPageConfiguration(
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0.1 Safari/605.1.15",
            allowsPictureInPicture: true,
            allowsJavaScript: true,
            allowsJavaScriptWindowsAutomatically: false,
            allowsAirPlayForMediaPlayback: true,
            allowsInspectableDebugging: true,
            allowsBackForwardNavigationGestures: true,
            mediaPlaybackRequiresUserAction: false,
            scriptMessageNames: ["listener", "linkHover", "mediaEvent", "passwordManager", "contextMenu"],
            userScripts: userScripts,
            privacySettings: privacySettings
        )
    }
}

final class BrowserEngine {
    private struct ProfileKey: Hashable {
        let identifier: UUID
        let isPrivate: Bool
    }

    static let shared = BrowserEngine()

    /// Store every tab that is in no browsing container shares, Firefox's "No
    /// container". A fixed constant rather than a fresh UUID, so the store survives
    /// relaunches and nobody is signed out by a restart.
    static let defaultStoreIdentifier = UUID(uuidString: "6E9F1C34-2B7A-4C05-9E1D-3A5B8C7D0F42")!
    private let profileCacheLock = NSLock()
    private var profileCache: [ProfileKey: BrowserEngineProfile] = [:]

    /// Held briefly so the warm-up view is not torn down before its load starts.
    @MainActor private var warmupView: WKWebView?

    /// Spins up WebKit's XPC services (WebContent, Networking, GPU) with a throwaway
    /// empty web view at launch. Without it, a window that opens onto the start page
    /// pays for the whole stack inside the first ⌘T keystroke; a window restoring a
    /// live tab warms it as a side effect and this is a cheap no-op on top.
    @MainActor
    func warmUp() {
        guard warmupView == nil else { return }
        let view = WKWebView(frame: .zero)
        view.loadHTMLString("", baseURL: nil)
        warmupView = view
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.warmupView = nil
        }
    }

    func makeProfile(identifier: UUID, isPrivate: Bool) -> BrowserEngineProfile {
        if isPrivate {
            return BrowserEngineProfile(identifier: identifier, isPrivate: true)
        }

        let key = ProfileKey(identifier: identifier, isPrivate: false)
        profileCacheLock.lock()
        defer { profileCacheLock.unlock() }

        if let profile = profileCache[key] {
            return profile
        }

        let profile = BrowserEngineProfile(identifier: identifier, isPrivate: false)
        profileCache[key] = profile
        return profile
    }

    /// Releases the cached profile for a store that is going away, so its
    /// `WKWebsiteDataStore` closes instead of staying open for the life of the app.
    /// Only safe once nothing is using the store, so deleting a container is the one
    /// caller.
    func dropProfile(identifier: UUID) {
        profileCacheLock.lock()
        defer { profileCacheLock.unlock() }
        profileCache[ProfileKey(identifier: identifier, isPrivate: false)] = nil
    }

    func makePage(
        profile: BrowserEngineProfile,
        configuration: BrowserPageConfiguration,
        delegate: BrowserPageDelegate?
    ) -> BrowserPage {
        BrowserPage(profile: profile, configuration: configuration, delegate: delegate)
    }
}
