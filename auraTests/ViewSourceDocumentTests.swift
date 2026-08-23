import Foundation
@testable import Aura
import Testing

@Suite("View source line model")
struct ViewSourceDocumentTests {
    @Test("lines are numbered from one and keep their text")
    func numbering() {
        let lines = ViewSourceDocument.lines(from: "<html>\n  <body>\n</html>")
        #expect(lines.map(\.id) == [1, 2, 3])
        #expect(lines.map(\.text) == ["<html>", "  <body>", "</html>"])
    }

    @Test("CRLF and lone CR each count as one break")
    func lineEndings() {
        #expect(ViewSourceDocument.lines(from: "a\r\nb\r\nc").map(\.text) == ["a", "b", "c"])
        #expect(ViewSourceDocument.lines(from: "a\rb").map(\.text) == ["a", "b"])
        #expect(ViewSourceDocument.lines(from: "a\r\n\r\nb").map(\.text) == ["a", "", "b"])
    }

    @Test("a single trailing break does not add a line, two do")
    func trailingNewline() {
        #expect(ViewSourceDocument.lines(from: "a\n").map(\.text) == ["a"])
        #expect(ViewSourceDocument.lines(from: "a\n\n").map(\.text) == ["a", ""])
        #expect(ViewSourceDocument.lines(from: "").isEmpty == false)
        #expect(ViewSourceDocument.lines(from: "").map(\.text) == [""])
    }

    @Test("the row count is capped so a generated page cannot fill the stack")
    func truncation() {
        let source = String(repeating: "x\n", count: ViewSourceDocument.maxLines + 500)
        #expect(ViewSourceDocument.lines(from: source).count == ViewSourceDocument.maxLines)
    }

    @Test("the gutter is sized by digit count, never below two")
    func gutterSizing() {
        #expect(ViewSourceDocument.gutterDigits(for: 0) == 2)
        #expect(ViewSourceDocument.gutterDigits(for: 9) == 2)
        #expect(ViewSourceDocument.gutterDigits(for: 10) == 2)
        #expect(ViewSourceDocument.gutterDigits(for: 100) == 3)
        #expect(ViewSourceDocument.gutterDigits(for: 12_345) == 5)
    }
}
