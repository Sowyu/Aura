import AppKit
import Foundation
@testable import Aura
import Testing

@Suite("Tab drag pasteboard")
@MainActor
struct TabDragPasteboardTests {
    private let board = NSPasteboard(name: NSPasteboard.Name("AuraTabDragTests"))

    private func writer() throws -> TabDragPasteboardWriter {
        let url = try #require(URL(string: "https://example.test/article"))
        return TabDragPasteboardWriter(tabID: UUID(), url: url, title: "An Article")
    }

    @Test("a tab carries its identity, its address and its name")
    func writableTypes() throws {
        let types = try writer().writableTypes(for: board)
        #expect(types.contains(.auraTabItem))
        #expect(types.contains(.URL))
        #expect(types.contains(.auraURLName))
        #expect(types.contains(.string))
        // The promise is what Finder turns into a link file.
        #expect(types.contains { $0.rawValue.contains("promise") })
    }

    @Test("each type reads back what it promised")
    func propertyLists() throws {
        let id = UUID()
        let url = try #require(URL(string: "https://example.test/article"))
        let subject = TabDragPasteboardWriter(tabID: id, url: url, title: "An Article")

        #expect(subject.pasteboardPropertyList(forType: .auraTabItem) as? String == id.uuidString)
        #expect(subject.pasteboardPropertyList(forType: .URL) as? String == url.absoluteString)
        #expect(subject.pasteboardPropertyList(forType: .string) as? String == url.absoluteString)
        #expect(subject.pasteboardPropertyList(forType: .auraURLName) as? String == "An Article")
    }

    @Test("only the file promise is marked promised")
    func writingOptions() throws {
        let subject = try writer()
        #expect(subject.writingOptions(forType: .URL, pasteboard: board).isEmpty)
        #expect(subject.writingOptions(forType: .auraTabItem, pasteboard: board).isEmpty)
        #expect(subject.writingOptions(forType: .auraURLName, pasteboard: board).isEmpty)
    }

    @Test("the promised file is a webloc plist naming the address")
    func weblocContents() throws {
        let url = try #require(URL(string: "https://example.test/article?x=1"))
        let data = try #require(WeblocFile.data(for: url))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        #expect((plist as? [String: String])?["URL"] == url.absoluteString)

        let delegate = TabWeblocPromiseDelegate(url: url, title: "An / Article: Named")
        let provider = NSFilePromiseProvider(fileType: WeblocFile.contentType, delegate: delegate)
        let name = delegate.filePromiseProvider(provider, fileNameForType: WeblocFile.contentType)
        #expect(name == "An - Article- Named.webloc")
    }

    @Test("a folder row still writes the bare item every intra-app drop reads")
    func folderRowIsUnchanged() throws {
        let view = TabDragSourceNSView()
        let id = UUID()
        view.rowID = id
        view.isFolder = true
        let item = try #require(view.pasteboardWriter() as? NSPasteboardItem)
        #expect(item.types == [.auraTabItem])
        #expect(item.string(forType: .auraTabItem) == id.uuidString)
    }

    @Test("an internal page row also stays a bare item")
    func internalPageRowIsUnchanged() throws {
        let view = TabDragSourceNSView()
        view.rowID = UUID()
        view.dragURL = URL.oraHome
        #expect(view.pasteboardWriter() is NSPasteboardItem)
    }

    @Test("a web tab row upgrades to the full writer")
    func webRowCarriesEverything() throws {
        let view = TabDragSourceNSView()
        view.rowID = UUID()
        view.dragURL = URL(string: "https://example.test/")
        view.dragTitle = "Example"
        #expect(view.pasteboardWriter() is TabDragPasteboardWriter)
    }

    @Test("only a drag carrying an address offers a copy outside the app")
    func sourceOperationFollowsTheWriter() {
        #expect(TabDragSourceCoordinator.operation(for: .withinApplication, carriesURL: true) == .move)
        #expect(TabDragSourceCoordinator.operation(for: .withinApplication, carriesURL: false) == .move)
        #expect(TabDragSourceCoordinator.operation(for: .outsideApplication, carriesURL: true) == .copy)
        // A folder or an `aura://` row: a copy cursor here promises a drop with nothing in it.
        #expect(TabDragSourceCoordinator.operation(for: .outsideApplication, carriesURL: false).isEmpty)
    }
}
