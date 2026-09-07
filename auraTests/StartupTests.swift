import AppKit
@testable import Aura
import SwiftData
import Testing

@MainActor
struct StartupTests {
    private final class TestWindow: NSWindow {
        var testKey = false
        var testVisible = false
        override var isKeyWindow: Bool { testKey }
        override var isVisible: Bool { testVisible }
    }

    @Test func reopeningChoosesABrowserInsteadOfSettings() {
        let settings = TestWindow()
        settings.identifier = NSUserInterfaceItemIdentifier("settings")
        settings.testKey = true
        settings.testVisible = true
        let hidden = TestWindow()
        hidden.identifier = NSUserInterfaceItemIdentifier("normal")
        let visible = TestWindow()
        visible.identifier = NSUserInterfaceItemIdentifier("private")
        visible.testVisible = true

        #expect(AppDelegate.browserWindow(in: [settings]) == nil)
        #expect(AppDelegate.browserWindow(in: [settings, hidden]) === hidden)
        #expect(AppDelegate.browserWindow(in: [settings, hidden, visible]) === visible)
        hidden.testKey = true
        #expect(AppDelegate.browserWindow(in: [settings, visible, hidden]) === hidden)
        #expect(AppDelegate.browserWindow(in: []) == nil)
    }

    @Test func launchSelectsTheNewestTabWithoutReorderingSavedTabs() throws {
        let store = try ModelContainer(
            for: TabContainer.self, History.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(store)
        let manager = TabManager(modelContainer: store, modelContext: context, mediaController: MediaController())
        let space = try #require(manager.activeContainer)
        let dates: [Date?] = [nil, Date(timeIntervalSince1970: 20), Date(timeIntervalSince1970: 10)]
        for (index, date) in dates.enumerated() {
            let tab = try Tab(
                url: #require(URL(string: "https://example.com/\(index)")),
                title: "Saved \(index)", container: space, type: .pinned,
                order: index, tabManager: manager, isPrivate: false
            )
            tab.lastAccessedAt = date
            context.insert(tab)
            space.tabs.append(tab)
        }
        try context.save()
        let originalOrder = space.tabs.map(\.id)
        let newest = try #require(space.tabs.first { $0.order == 1 })
        let reopened = TabManager(modelContainer: store, modelContext: context, mediaController: MediaController())
        #expect(reopened.activeTab === newest)
        #expect(newest.maybeIsActive)
        #expect(space.tabs.map(\.id) == originalOrder)
    }
}
