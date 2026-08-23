import Foundation

/// A page's permission request that is still waiting on the user.
///
/// `decide` is WebKit's own reply block. WebKit leaves the page hanging on a block that
/// is never called, so every request that leaves `pending` has to be answered, including
/// the ones dropped because the tab navigated away.
struct SitePermissionRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    /// Every grant this request covers. A `getUserMedia` asking for both devices is two.
    let kinds: [SitePermissionKind]
    /// Registrable domain, which is the key a remembered decision is stored under.
    let host: String
    /// What the prompt shows, for example `https://meet.example.com`.
    let origin: String
    let isPrivate: Bool
    let decide: (BrowserPermissionDecision) -> Void

    /// Two requests that would put the same question on screen for the same tab.
    func asksTheSameAs(_ other: SitePermissionRequest) -> Bool {
        tabID == other.tabID && host == other.host && kinds == other.kinds
    }
}

extension BrowserPermissionKind {
    /// Which stored grants a request covers. A combined request is two grants, so a site
    /// given the microphone is still asked about the camera.
    var siteKinds: [SitePermissionKind] {
        switch self {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        case .cameraAndMicrophone: return [.camera, .microphone]
        }
    }
}

extension Array where Element == SitePermissionKind {
    /// "camera", "microphone", "camera and microphone" for the prompt's sentence.
    var phrase: String {
        map(\.phrase).joined(separator: " and ")
    }
}

/// Holds the permission questions Aura has not answered yet, one queue for the whole
/// app keyed by tab.
///
/// It is a queue rather than a single slot because a page can ask twice before anyone
/// clicks, and a prompt must never run a modal loop: a request raised in one window has
/// to leave every other window usable, including the web processes parked in a
/// synchronous injected-bundle ask.
@MainActor
@Observable
final class SitePermissionCoordinator {
    static let shared = SitePermissionCoordinator()

    private(set) var pending: [SitePermissionRequest] = []

    /// Answers from the stored grants when the site already has one for every kind
    /// asked about, and only queues a prompt otherwise.
    func request(
        kind: BrowserPermissionKind,
        origin: URL?,
        tabID: UUID,
        isPrivate: Bool,
        decide: @escaping (BrowserPermissionDecision) -> Void
    ) {
        let kinds = kind.siteKinds
        guard let origin, let host = registrableDomain(from: origin) else {
            // An opaque origin (a `data:` or `about:` frame) has nothing a decision could
            // be remembered against, so it is refused rather than asked about.
            decide(.deny)
            return
        }

        let stored = SettingsStore.shared.sitePermissions(forHost: host)
        if let remembered = SitePermissionResolver.decision(for: kinds, in: stored) {
            decide(remembered ? .grant : .deny)
            return
        }

        pending.append(
            SitePermissionRequest(
                tabID: tabID,
                kinds: kinds,
                host: host,
                origin: origin.absoluteString,
                isPrivate: isPrivate,
                decide: decide
            )
        )
    }

    /// The prompt to show for a tab, or nil when it has nothing outstanding.
    func request(forTab tabID: UUID) -> SitePermissionRequest? {
        pending.first { $0.tabID == tabID }
    }

    func answer(_ request: SitePermissionRequest, with answer: SitePermissionAnswer) {
        // A private window never writes a grant: remembering one would outlive exactly
        // the session the user asked to leave no trace of.
        if answer.remember, !request.isPrivate {
            SettingsStore.shared.recordSitePermission(answer, kinds: request.kinds, host: request.host)
        }

        // Anything the same page asked for a second time while the prompt was up takes
        // the same answer instead of stacking an identical prompt behind it.
        let answered = pending.filter { $0.asksTheSameAs(request) }
        pending.removeAll { $0.asksTheSameAs(request) }
        let decision: BrowserPermissionDecision = answer.isAllowed ? .grant : .deny
        for outstanding in answered {
            outstanding.decide(decision)
        }
    }

    /// Refuses everything still waiting on a tab. Called when the tab starts a new
    /// navigation or goes away, so no page is left waiting on a reply that will never come.
    func cancelRequests(forTab tabID: UUID) {
        let dropped = pending.filter { $0.tabID == tabID }
        guard !dropped.isEmpty else { return }
        pending.removeAll { $0.tabID == tabID }
        for request in dropped {
            request.decide(.deny)
        }
    }
}
