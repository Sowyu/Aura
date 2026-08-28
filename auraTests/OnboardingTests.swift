import AppKit
import Foundation
@testable import Aura
import SwiftData
import Testing

/// When the welcome flow shows, how it steps, and what its last screen does to the
/// profile — the parts that do not need a window.
@MainActor
struct OnboardingTests {
    private func makeManager() throws -> (TabManager, TabContainer) {
        let modelContainer = try ModelContainer(
            for: TabContainer.self, History.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(modelContainer)
        let manager = TabManager(
            modelContainer: modelContainer,
            modelContext: context,
            mediaController: MediaController()
        )
        return (manager, manager.createContainer(name: "Default"))
    }

    // MARK: - Policy

    @Test func showsOnceAndNeverInAPrivateWindow() {
        #expect(OnboardingPolicy.shouldShow(completed: false, isPrivate: false))
        #expect(!OnboardingPolicy.shouldShow(completed: true, isPrivate: false))
        #expect(!OnboardingPolicy.shouldShow(completed: false, isPrivate: true))
    }

    /// An upgrade lands with spaces and tabs already there; a fresh profile has one
    /// space and at most the home page.
    @Test func aProfileWithHistoryIsNotAFirstRun() {
        #expect(!OnboardingPolicy.isExistingProfile(spaceCount: 1, tabsBeyondHome: 0))
        #expect(!OnboardingPolicy.isExistingProfile(spaceCount: 0, tabsBeyondHome: 0))
        #expect(OnboardingPolicy.isExistingProfile(spaceCount: 2, tabsBeyondHome: 0))
        #expect(OnboardingPolicy.isExistingProfile(spaceCount: 1, tabsBeyondHome: 1))
    }

    // MARK: - Stepping

    @Test func stepsRunForwardAndBackAndStopAtTheEnds() {
        let draft = OnboardingDraft()
        #expect(draft.isFirst)
        draft.goBack()
        #expect(draft.step == .welcome)

        for _ in OnboardingStep.allCases { draft.advance() }
        #expect(draft.step == .finish)
        draft.advance()
        #expect(draft.step == .finish)

        draft.goBack()
        #expect(draft.step == .blocking)
    }

    @Test func togglingASiteSelectsAndDeselectsIt() throws {
        let draft = OnboardingDraft()
        let site = try #require(OnboardingSites.suggestions.first)
        draft.toggle(site)
        #expect(draft.selectedSites.map(\.id) == [site.id])
        draft.toggle(site)
        #expect(draft.selectedSites.isEmpty)
    }

    @Test func anUntouchedSpaceScreenChangesNothing() {
        let draft = OnboardingDraft()
        #expect(!draft.customisesSpace)
        draft.spaceName = "  "
        #expect(!draft.customisesSpace)
        draft.spaceName = "Work"
        #expect(draft.customisesSpace)
    }

    // MARK: - Key guard

    /// Chrome shortcuts stay out while the card is up; editing and app-level chords
    /// and every plain key go through.
    @Test func commandChordsAreSwallowedExceptEditingAndAppOnes() {
        #expect(OnboardingKeyGuard.swallows(key: "t", modifiers: [.command]))
        #expect(OnboardingKeyGuard.swallows(key: "w", modifiers: [.command]))
        #expect(OnboardingKeyGuard.swallows(key: "s", modifiers: [.command, .shift]))
        #expect(OnboardingKeyGuard.swallows(key: ",", modifiers: [.command]))

        #expect(!OnboardingKeyGuard.swallows(key: "q", modifiers: [.command]))
        #expect(!OnboardingKeyGuard.swallows(key: "h", modifiers: [.command]))
        #expect(!OnboardingKeyGuard.swallows(key: "v", modifiers: [.command]))
        #expect(!OnboardingKeyGuard.swallows(key: "Z", modifiers: [.command, .shift]))

        #expect(!OnboardingKeyGuard.swallows(key: "t", modifiers: []))
        #expect(!OnboardingKeyGuard.swallows(key: "\r", modifiers: []))
        #expect(!OnboardingKeyGuard.swallows(key: "t", modifiers: [.control]))
    }

    // MARK: - Commit

    /// The chosen sites become favourites of the space with their pinned URL set, and
    /// none of them gets a web view: they load on the first click, not now.
    @Test func chosenSitesBecomeUnloadedFavourites() throws {
        let (manager, space) = try makeManager()
        let picked = Array(OnboardingSites.suggestions.prefix(2))

        OnboardingCommit.addFavorites(picked, to: space, tabManager: manager)

        let favs = space.tabs.filter { $0.type == .fav }
        #expect(favs.count == 2)
        for tab in favs {
            #expect(tab.savedURL == tab.url)
            #expect(!tab.isWebViewReady)
            #expect(picked.contains { $0.url == tab.url })
        }
        // The active tab is untouched: nothing was activated on the way in.
        #expect(manager.activeTab == nil)
    }

    @Test func noSitesMeansNoTabs() throws {
        let (manager, space) = try makeManager()
        OnboardingCommit.addFavorites([], to: space, tabManager: manager)
        #expect(space.tabs.isEmpty)
    }
}
