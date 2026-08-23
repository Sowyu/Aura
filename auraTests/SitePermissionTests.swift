import Foundation
@testable import Aura
import Testing

struct SitePermissionResolverTests {
    @Test func nothingStoredMeansAsk() {
        #expect(SitePermissionResolver.decision(for: [.camera], in: nil) == nil)
        #expect(
            SitePermissionResolver.decision(
                for: [.camera],
                in: SitePermissionSettings(host: "example.com", microphone: true)
            ) == nil
        )
    }

    @Test func aStoredAnswerDecidesWithoutAsking() {
        let allowed = SitePermissionSettings(host: "example.com", camera: true)
        let blocked = SitePermissionSettings(host: "example.com", camera: false)

        #expect(SitePermissionResolver.decision(for: [.camera], in: allowed) == true)
        #expect(SitePermissionResolver.decision(for: [.camera], in: blocked) == false)
    }

    @Test func aCombinedRequestNeedsBothHalves() {
        let both: [SitePermissionKind] = [.camera, .microphone]

        // One half answered is not an answer to the pair.
        #expect(
            SitePermissionResolver.decision(
                for: both,
                in: SitePermissionSettings(host: "example.com", camera: true)
            ) == nil
        )
        #expect(
            SitePermissionResolver.decision(
                for: both,
                in: SitePermissionSettings(host: "example.com", camera: true, microphone: true)
            ) == true
        )
        // A single block refuses the pair even when the other half is allowed.
        #expect(
            SitePermissionResolver.decision(
                for: both,
                in: SitePermissionSettings(host: "example.com", camera: true, microphone: false)
            ) == false
        )
    }

    @Test func allowOnceIsNotStored() {
        let map = SitePermissionResolver.applying(
            SitePermissionAnswer(isAllowed: true, remember: false),
            kinds: [.camera],
            host: "example.com",
            to: [:]
        )
        #expect(map.isEmpty)
    }

    @Test func rememberedAnswersAreStoredPerKind() {
        var map = SitePermissionResolver.applying(
            SitePermissionAnswer(isAllowed: true, remember: true),
            kinds: [.camera, .microphone],
            host: "example.com",
            to: [:]
        )
        #expect(map["example.com"]?.camera == true)
        #expect(map["example.com"]?.microphone == true)
        #expect(map["example.com"]?.location == nil)

        // A later answer replaces only the kinds it covers.
        map = SitePermissionResolver.applying(
            SitePermissionAnswer(isAllowed: false, remember: true),
            kinds: [.microphone],
            host: "example.com",
            to: map
        )
        #expect(map["example.com"]?.camera == true)
        #expect(map["example.com"]?.microphone == false)
    }

    @Test func aSettingsRowKnowsWhenItIsEmpty() {
        var entry = SitePermissionSettings(host: "example.com")
        #expect(entry.isEmpty)
        #expect(entry.decided.isEmpty)

        entry.set(false, for: .camera)
        #expect(!entry.isEmpty)
        #expect(entry.decided.map(\.kind) == [.camera])

        entry.set(nil, for: .camera)
        #expect(entry.isEmpty)
    }

    /// Blobs written before grants became three-state carried plain booleans.
    @Test func oldBlobsWithPlainBooleansStillDecode() throws {
        let json = Data(
            #"{"host":"example.com","camera":true,"microphone":false,"location":false,"notifications":false}"#.utf8
        )
        let decoded = try JSONDecoder().decode(SitePermissionSettings.self, from: json)
        #expect(decoded.camera == true)
        #expect(decoded.microphone == false)
        #expect(decoded.host == "example.com")
    }
}

@MainActor
struct SitePermissionStoreTests {
    private func withCleanPermissions(_ body: () -> Void) {
        let store = SettingsStore.shared
        let baseline = store.sitePermissions
        defer { store.sitePermissions = baseline }
        store.sitePermissions = [:]
        body()
    }

    @Test func grantsAreKeyedByRegistrableDomain() {
        withCleanPermissions {
            let store = SettingsStore.shared
            store.setSitePermission(true, for: .camera, host: "meet.example.com")

            #expect(store.sitePermissions(forHost: "example.com")?.camera == true)
            #expect(store.sitePermissions(forHost: "other.example.com")?.camera == true)
            #expect(store.sitePermissions(forHost: "example.org") == nil)
        }
    }

    @Test func aHostWithNoGrantsLeftDropsOutOfTheMap() {
        withCleanPermissions {
            let store = SettingsStore.shared
            store.setSitePermission(true, for: .camera, host: "example.com")
            store.setSitePermission(false, for: .microphone, host: "example.com")
            #expect(store.sitePermissions.count == 1)

            store.setSitePermission(nil, for: .camera, host: "example.com")
            #expect(store.sitePermissions["example.com"]?.microphone == false)

            store.setSitePermission(nil, for: .microphone, host: "example.com")
            #expect(store.sitePermissions.isEmpty)
        }
    }

    @Test func removingASiteTakesEverySubdomainWithIt() {
        withCleanPermissions {
            let store = SettingsStore.shared
            store.setSitePermission(true, for: .camera, host: "example.com")
            store.removeSitePermission(host: "meet.example.com")
            #expect(store.sitePermissions.isEmpty)
        }
    }
}

@MainActor
struct SitePermissionCoordinatorTests {
    private func label(_ decision: BrowserPermissionDecision?) -> String {
        switch decision {
        case .grant: return "grant"
        case .deny: return "deny"
        case .prompt: return "prompt"
        case nil: return "unanswered"
        }
    }

    /// Isolates a run from whatever the shared store and queue happen to hold.
    private func withCleanCoordinator(tab: UUID, _ body: () -> Void) {
        let store = SettingsStore.shared
        let baseline = store.sitePermissions
        defer {
            SitePermissionCoordinator.shared.cancelRequests(forTab: tab)
            store.sitePermissions = baseline
        }
        store.sitePermissions = [:]
        body()
    }

    @Test func aRememberedAnswerNeverRaisesAPrompt() throws {
        let tab = UUID()
        withCleanCoordinator(tab: tab) {
            let coordinator = SitePermissionCoordinator.shared
            SettingsStore.shared.setSitePermission(true, for: .camera, host: "example.com")

            var answered: BrowserPermissionDecision?
            coordinator.request(
                kind: .camera,
                origin: URL(string: "https://meet.example.com"),
                tabID: tab,
                isPrivate: false
            ) { answered = $0 }

            #expect(label(answered) == "grant")
            #expect(coordinator.request(forTab: tab) == nil)

            SettingsStore.shared.setSitePermission(false, for: .microphone, host: "example.com")
            var denied: BrowserPermissionDecision?
            coordinator.request(
                kind: .microphone,
                origin: URL(string: "https://example.com"),
                tabID: tab,
                isPrivate: false
            ) { denied = $0 }

            #expect(label(denied) == "deny")
            #expect(coordinator.request(forTab: tab) == nil)
        }
    }

    @Test func anUnansweredSiteQueuesAPromptAndAllowOnceIsNotPersisted() throws {
        let tab = UUID()
        withCleanCoordinator(tab: tab) {
            let coordinator = SitePermissionCoordinator.shared
            var answered: BrowserPermissionDecision?
            coordinator.request(
                kind: .cameraAndMicrophone,
                origin: URL(string: "https://example.com/call"),
                tabID: tab,
                isPrivate: false
            ) { answered = $0 }

            #expect(label(answered) == "unanswered")
            let pending = coordinator.request(forTab: tab)
            #expect(pending?.host == "example.com")
            #expect(pending?.kinds == [.camera, .microphone])

            guard let pending else { return }
            coordinator.answer(pending, with: SitePermissionAnswer(isAllowed: true, remember: false))

            #expect(label(answered) == "grant")
            #expect(coordinator.request(forTab: tab) == nil)
            #expect(SettingsStore.shared.sitePermissions.isEmpty)
        }
    }

    @Test func rememberingWritesTheGrantButAPrivateWindowNeverDoes() throws {
        let tab = UUID()
        withCleanCoordinator(tab: tab) {
            let coordinator = SitePermissionCoordinator.shared
            coordinator.request(
                kind: .camera,
                origin: URL(string: "https://example.com"),
                tabID: tab,
                isPrivate: false
            ) { _ in }
            if let pending = coordinator.request(forTab: tab) {
                coordinator.answer(pending, with: SitePermissionAnswer(isAllowed: false, remember: true))
            }
            #expect(SettingsStore.shared.sitePermissions["example.com"]?.camera == false)

            SettingsStore.shared.sitePermissions = [:]
            coordinator.request(
                kind: .camera,
                origin: URL(string: "https://example.com"),
                tabID: tab,
                isPrivate: true
            ) { _ in }
            if let pending = coordinator.request(forTab: tab) {
                coordinator.answer(pending, with: SitePermissionAnswer(isAllowed: true, remember: true))
            }
            #expect(SettingsStore.shared.sitePermissions.isEmpty)
        }
    }

    @Test func anOriginWithoutASiteIsRefusedRatherThanAsked() throws {
        let tab = UUID()
        withCleanCoordinator(tab: tab) {
            var answered: BrowserPermissionDecision?
            SitePermissionCoordinator.shared.request(
                kind: .camera,
                origin: URL(string: "about:blank"),
                tabID: tab,
                isPrivate: false
            ) { answered = $0 }

            #expect(label(answered) == "deny")
            #expect(SitePermissionCoordinator.shared.request(forTab: tab) == nil)
        }
    }

    @Test func aDroppedRequestIsAnsweredSoThePageIsNotLeftWaiting() throws {
        let tab = UUID()
        withCleanCoordinator(tab: tab) {
            let coordinator = SitePermissionCoordinator.shared
            var answered: BrowserPermissionDecision?
            coordinator.request(
                kind: .microphone,
                origin: URL(string: "https://example.com"),
                tabID: tab,
                isPrivate: false
            ) { answered = $0 }
            #expect(label(answered) == "unanswered")

            coordinator.cancelRequests(forTab: tab)
            #expect(label(answered) == "deny")
            #expect(coordinator.request(forTab: tab) == nil)
        }
    }

    @Test func aSecondIdenticalAskRidesOnThePromptAlreadyUp() throws {
        let tab = UUID()
        withCleanCoordinator(tab: tab) {
            let coordinator = SitePermissionCoordinator.shared
            var first: BrowserPermissionDecision?
            var second: BrowserPermissionDecision?
            for handler in [{ first = $0 }, { (decision: BrowserPermissionDecision) in second = decision }] {
                coordinator.request(
                    kind: .camera,
                    origin: URL(string: "https://example.com"),
                    tabID: tab,
                    isPrivate: false,
                    decide: handler
                )
            }
            #expect(coordinator.pending.filter { $0.tabID == tab }.count == 2)

            guard let pending = coordinator.request(forTab: tab) else { return }
            coordinator.answer(pending, with: SitePermissionAnswer(isAllowed: true, remember: false))

            #expect(label(first) == "grant")
            #expect(label(second) == "grant")
            #expect(coordinator.request(forTab: tab) == nil)
        }
    }
}
