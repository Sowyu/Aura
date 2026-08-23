import Foundation
@testable import Aura
import Testing

struct SiteZoomLadderTests {
    @Test func stepsOneRungAtATime() {
        #expect(SiteZoom.stepped(from: 1, by: 1) == 1.1)
        #expect(SiteZoom.stepped(from: 1.1, by: 1) == 1.25)
        #expect(SiteZoom.stepped(from: 1, by: -1) == 0.9)
        #expect(SiteZoom.stepped(from: 0.9, by: -1) == 0.8)
    }

    @Test func stoppingAtTheEndsOfTheLadder() {
        #expect(SiteZoom.levels.first == SiteZoom.minimum)
        #expect(SiteZoom.levels.last == SiteZoom.maximum)
        #expect(SiteZoom.stepped(from: SiteZoom.maximum, by: 1) == SiteZoom.maximum)
        #expect(SiteZoom.stepped(from: SiteZoom.minimum, by: -1) == SiteZoom.minimum)
        // Anything past the ends is pulled back onto the ladder first.
        #expect(SiteZoom.stepped(from: 12, by: 1) == SiteZoom.maximum)
        #expect(SiteZoom.stepped(from: 0.01, by: -1) == SiteZoom.minimum)
        #expect(SiteZoom.clamped(.nan) == SiteZoom.default)
    }

    @Test func aLevelBetweenRungsMovesPastItRatherThanSnappingBack() {
        // A hand-edited plist or an older build can leave a level off the ladder; a
        // keystroke must still change something.
        #expect(SiteZoom.stepped(from: 1.05, by: 1) == 1.1)
        #expect(SiteZoom.stepped(from: 1.05, by: -1) == 1)
    }

    @Test func labelsReadAsPercentages() {
        #expect(SiteZoom.percentLabel(1) == "100%")
        #expect(SiteZoom.percentLabel(1.25) == "125%")
        #expect(SiteZoom.percentLabel(0.67) == "67%")
        #expect(SiteZoom.isDefault(1))
        #expect(!SiteZoom.isDefault(1.1))
    }
}

@MainActor
struct SiteZoomPersistenceTests {
    /// Every test here writes the shared store, so each one puts back what it found.
    private func withCleanZoomLevels(_ body: () -> Void) {
        let store = SettingsStore.shared
        let baseline = store.siteZoomLevels
        defer { store.siteZoomLevels = baseline }
        store.siteZoomLevels = [:]
        body()
    }

    @Test func levelsAreKeyedByRegistrableDomainSoSubdomainsShare() {
        withCleanZoomLevels {
            let store = SettingsStore.shared
            store.setZoomLevel(1.5, forHost: "news.example.com")

            #expect(store.siteZoomLevels == ["example.com": 1.5])
            #expect(store.zoomLevel(forHost: "example.com") == 1.5)
            #expect(store.zoomLevel(forHost: "a.b.example.com") == 1.5)
            // A different registrable domain keeps the default.
            #expect(store.zoomLevel(forHost: "other.org") == SiteZoom.default)
        }
    }

    @Test func oneHundredPercentRemovesTheEntry() {
        withCleanZoomLevels {
            let store = SettingsStore.shared
            store.setZoomLevel(2, forHost: "example.com")
            #expect(store.siteZoomLevels["example.com"] == 2)

            store.setZoomLevel(1, forHost: "example.com")
            #expect(store.siteZoomLevels["example.com"] == nil)
            #expect(store.siteZoomLevels.isEmpty)
            #expect(store.zoomLevel(forHost: "example.com") == SiteZoom.default)
        }
    }

    @Test func storedLevelsAreClampedToTheLadder() {
        withCleanZoomLevels {
            let store = SettingsStore.shared
            store.setZoomLevel(99, forHost: "example.com")
            #expect(store.zoomLevel(forHost: "example.com") == SiteZoom.maximum)

            store.setZoomLevel(0.01, forHost: "other.org")
            #expect(store.zoomLevel(forHost: "other.org") == SiteZoom.minimum)
        }
    }

    @Test func hostsWithoutARegistrableDomainAreIgnored() {
        withCleanZoomLevels {
            let store = SettingsStore.shared
            store.setZoomLevel(1.5, forHost: "")
            #expect(store.siteZoomLevels.isEmpty)
            #expect(store.zoomLevel(forHost: "") == SiteZoom.default)
        }
    }

    @Test func theLevelForAURLFollowsItsSite() throws {
        withCleanZoomLevels {
            SettingsStore.shared.setZoomLevel(1.25, forHost: "example.com")
            let page = URL(string: "https://sub.example.com/deep/path?q=1")
            #expect(SiteZoomController.level(for: page) == 1.25)
            // A URL with no host at all cannot be zoomed.
            #expect(SiteZoomController.level(for: URL(string: "about:blank")) == SiteZoom.default)
            #expect(SiteZoomController.level(for: nil) == SiteZoom.default)
        }
    }
}
