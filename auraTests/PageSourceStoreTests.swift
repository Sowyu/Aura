import Foundation
@testable import Aura
import Testing

@Suite("Captured page source")
@MainActor
struct PageSourceStoreTests {
    @Test("a capture reads back by target address")
    func storeAndRead() throws {
        let store = PageSourceStore.shared
        store.clear()
        let target = try #require(URL(string: "https://example.test/a"))
        store.store("<html>a</html>", for: target)
        #expect(store.html(for: target) == "<html>a</html>")

        let other = try #require(URL(string: "https://example.test/b"))
        #expect(store.html(for: other) == nil)
        store.clear()
    }

    @Test("the oldest capture is dropped once the store is full")
    func eviction() throws {
        let store = PageSourceStore.shared
        store.clear()
        for index in 0 ... 6 {
            let url = try #require(URL(string: "https://example.test/\(index)"))
            store.store("page \(index)", for: url)
        }
        let first = try #require(URL(string: "https://example.test/0"))
        let last = try #require(URL(string: "https://example.test/6"))
        #expect(store.html(for: first) == nil)
        #expect(store.html(for: last) == "page 6")
        store.clear()
    }

    @Test("bytes decode as UTF-8 first and fall back rather than failing")
    func decoding() throws {
        #expect(PageSourceLoader.decode(Data("<p>héllo</p>".utf8)) == "<p>héllo</p>")
        let latin1 = try #require("<p>café</p>".data(using: .isoLatin1))
        #expect(PageSourceLoader.decode(latin1) == "<p>café</p>")
    }

    @Test("a non-web address is not fetched")
    func unfetchableScheme() async throws {
        let target = try #require(URL(string: "ftp://example.test/a"))
        await #expect(throws: PageSourceLoader.Failure.notFetchable) {
            _ = try await PageSourceLoader.fetch(target)
        }
    }
}
