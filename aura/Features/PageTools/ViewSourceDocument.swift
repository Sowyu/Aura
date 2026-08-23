import Foundation

/// One numbered row of the view-source page.
struct SourceLine: Identifiable, Equatable {
    /// The line number, one based, which is also the row's identity.
    let id: Int
    let text: String
}

/// Turns raw markup into the rows the view draws. Kept apart from the view so line
/// splitting and gutter sizing can be checked without a window.
enum ViewSourceDocument {
    /// A page with a runaway generated body would otherwise put a hundred thousand rows
    /// in the lazy stack, and the scroll bar becomes useless long before that.
    /// ponytail: hard cap, revisit if anyone needs to read past line 50000.
    static let maxLines = 50_000

    /// `source` split into numbered lines.
    ///
    /// CRLF and lone CR both count as one break: splitting on a character set would make
    /// every CRLF produce a phantom empty line, and Windows-authored pages are full of
    /// them. A single trailing break is dropped, because a file ending in a newline has
    /// no last line to number.
    static func lines(from source: String) -> [SourceLine] {
        var normalised = source.replacingOccurrences(of: "\r\n", with: "\n")
        normalised = normalised.replacingOccurrences(of: "\r", with: "\n")
        if normalised.hasSuffix("\n") { normalised.removeLast() }
        let split = normalised.components(separatedBy: "\n").prefix(maxLines)
        return split.enumerated().map { SourceLine(id: $0.offset + 1, text: $0.element) }
    }

    /// Digits the gutter has to hold, so every row's number is right-aligned against the
    /// same edge instead of the column jittering at line 10, 100 and 1000.
    static func gutterDigits(for lineCount: Int) -> Int {
        max(2, String(max(lineCount, 1)).count)
    }
}
