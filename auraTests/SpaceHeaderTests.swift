import AppKit
import Foundation
@testable import Aura
import SwiftData
import Testing

/// The sidebar space header: reordering spaces, and the window rule that decides which
/// sidebar claims a posted command such as "New Folder".
@MainActor
struct SpaceHeaderTests {
    private func makeManager() throws -> TabManager {
        let modelContainer = try ModelContainer(
            for: TabContainer.self, History.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return TabManager(
            modelContainer: modelContainer,
            modelContext: ModelContext(modelContainer),
            mediaController: MediaController()
        )
    }

    /// The list as the sidebar sorts it: by `order`, then creation date.
    private func sorted(_ spaces: [TabContainer]) -> [TabContainer] {
        spaces.sorted {
            $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order
        }
    }

    private func makeSpaces(_ manager: TabManager, _ names: [String]) -> [TabContainer] {
        names.map { manager.createContainer(name: $0) }
    }

    // MARK: - Reordering

    @Test func newSpacesLandAfterTheExistingOnes() throws {
        let manager = try makeManager()
        let spaces = makeSpaces(manager, ["one", "two", "three"])
        #expect(sorted(spaces).map(\.name) == ["one", "two", "three"])
        // The manager makes a default space during init, so orders start above zero.
        #expect(spaces.map(\.order) == spaces.map(\.order).sorted())
    }

    @Test func movingASpaceUpSwapsItWithItsNeighbour() throws {
        let manager = try makeManager()
        let spaces = sorted(makeSpaces(manager, ["one", "two", "three"]))

        #expect(manager.move(container: spaces[2], by: -1, in: spaces))
        #expect(sorted(spaces).map(\.name) == ["one", "three", "two"])
    }

    @Test func movingASpaceDownSwapsItWithItsNeighbour() throws {
        let manager = try makeManager()
        let spaces = sorted(makeSpaces(manager, ["one", "two", "three"]))

        #expect(manager.move(container: spaces[0], by: 1, in: spaces))
        #expect(sorted(spaces).map(\.name) == ["two", "one", "three"])
    }

    @Test func movingPastEitherEndDoesNothing() throws {
        let manager = try makeManager()
        let spaces = sorted(makeSpaces(manager, ["one", "two"]))

        #expect(!manager.move(container: spaces[0], by: -1, in: spaces))
        #expect(!manager.move(container: spaces[1], by: 1, in: spaces))
        #expect(sorted(spaces).map(\.name) == ["one", "two"])
    }

    @Test func reorderingLeavesEveryPositionUnique() throws {
        let manager = try makeManager()
        let spaces = sorted(makeSpaces(manager, ["one", "two", "three", "four"]))

        manager.move(container: spaces[3], by: -2, in: spaces)
        let orders = spaces.map(\.order)
        #expect(Set(orders).count == orders.count)
        #expect(sorted(spaces).map(\.name) == ["one", "four", "two", "three"])
    }

    // MARK: - Which window claims a command

    private func note(from sender: NSWindow?) -> Notification {
        Notification(name: .newTabFolder, object: sender)
    }

    /// The sidebar posts with its own `\.window`, which is nil until `WindowReader` binds
    /// it; the page that handles it never gets a window environment at all. Both sides
    /// have to fall back to the key window or the command is dropped on the floor.
    @Test func aSenderlessPostIsClaimedByTheKeyWindow() {
        let key = NSWindow()
        #expect(WindowEventScope.windowOrKey.accepts(note(from: nil), window: nil, keyWindow: key))
    }

    @Test func aPostNamingTheKeyWindowIsClaimedByAPageWithNoWindow() {
        let key = NSWindow()
        #expect(WindowEventScope.windowOrKey.accepts(note(from: key), window: nil, keyWindow: key))
        #expect(WindowEventScope.window.accepts(note(from: key), window: nil, keyWindow: key))
    }

    @Test func anotherWindowsPostIsIgnored() {
        let key = NSWindow()
        let other = NSWindow()
        #expect(!WindowEventScope.windowOrKey.accepts(note(from: other), window: nil, keyWindow: key))
        #expect(!WindowEventScope.windowOrKey.accepts(note(from: nil), window: other, keyWindow: key))
    }
}
