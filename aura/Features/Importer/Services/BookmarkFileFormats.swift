import Foundation

/// One saved page read out of another browser's export, or on its way into one.
///
/// The same type carries both directions so the round trip is a single equality check:
/// what `NetscapeBookmarks.export` writes, `NetscapeBookmarks.parse` has to give back.
/// `folderName` is nil for the bookmarks bar itself, which is the only nesting Aura's
/// `BookmarkFolder` has.
struct ImportedBookmark: Equatable {
    var title: String
    var urlString: String
    var folderName: String?
    var addedAt: Date?

    init(title: String, urlString: String, folderName: String? = nil, addedAt: Date? = nil) {
        self.title = title
        self.urlString = urlString
        self.folderName = folderName
        self.addedAt = addedAt
    }
}

/// Schemes a bookmark is allowed to carry across the import boundary.
///
/// An allow-list rather than a deny-list: an export file is user-supplied input, and the
/// rows Aura refuses are exactly the ones that are not pages. Firefox writes `place:`
/// queries ("Most Visited"), Chrome and Edge write `chrome://`/`edge://` pages, and any
/// of the three happily exports a `javascript:` bookmarklet, which is a saved script
/// that runs against whatever page is open when someone clicks the bar.
enum BookmarkImportRules {
    static let importableSchemes: Set<String> = ["http", "https", "ftp", "ftps", "file"]

    static func isImportable(_ urlString: String) -> Bool {
        guard let scheme = URL(string: urlString)?.scheme?.lowercased() else { return false }
        return importableSchemes.contains(scheme)
    }

    /// Folder names every browser uses for the row of bookmarks under its toolbar.
    /// Matched alongside the `PERSONAL_TOOLBAR_FOLDER` attribute because Edge and some
    /// exporters leave the attribute off and only the name says which folder is the bar.
    static let toolbarFolderNames: Set<String> = [
        "bookmarks bar",
        "bookmarks toolbar",
        "bookmarks toolbar folder",
        "favorites bar",
        "favourites bar",
        "toolbar",
        "bookmarksbar"
    ]

    static func isToolbarName(_ name: String) -> Bool {
        toolbarFolderNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Where a row lands once the export's arbitrary nesting is flattened to Aura's one
    /// level: the bar, or one named folder.
    ///
    /// Two rules, and they are the ones a person would draw by hand. Pages sitting
    /// directly in the toolbar folder are the bar, because that is what the bar is in the
    /// browser they came from. Anything deeper collapses into its outermost real folder,
    /// so a four-deep `Work/Clients/Acme/Invoices` bookmark arrives in `Work` rather than
    /// being dropped or spawning a folder tree the model cannot hold.
    static func flattenedFolderName(chain: [(name: String, isToolbar: Bool)]) -> String? {
        guard let first = chain.first else { return nil }
        if first.isToolbar {
            return chain.count >= 2 ? chain[1].name : nil
        }
        return first.name
    }
}

// MARK: - Netscape bookmark file

/// The `<!DOCTYPE NETSCAPE-Bookmark-file-1>` format, which is what Chrome, Firefox and
/// Edge all write when asked to export bookmarks, and the only format all three read
/// back. One parser covers the three because the differences between them are folder
/// names, not syntax.
///
/// Hand-written scanner rather than an HTML parser: the format is not valid HTML. Real
/// exports leave `<DT>` and `<p>` unclosed, put `<DL><p>` where a nesting parser expects
/// `<DL>`, and drop bare `<HR>` separators between rows. Every strict parser either
/// rejects those files or silently re-nests them, and both answers lose bookmarks.
enum NetscapeBookmarks {
    // MARK: Parsing

    static func parse(_ data: Data) -> [ImportedBookmark] {
        guard let text = decodeText(data) else { return [] }
        var scanner = TagScanner(text)
        var results: [ImportedBookmark] = []

        // Folder headings, innermost last. The outermost `<DL>` wraps the whole file and
        // has no heading, so it contributes nothing and the chain stays empty for rows
        // that sit at the top level.
        var openFolders: [(name: String?, isToolbar: Bool)] = []
        // An `<H3>` names the `<DL>` that follows it, not the one it sits in.
        var pendingFolder: (name: String, isToolbar: Bool)?

        while let tag = scanner.nextTag() {
            switch (tag.name, tag.isClosing) {
            case ("dl", false):
                openFolders.append((pendingFolder?.name, pendingFolder?.isToolbar ?? false))
                pendingFolder = nil
            case ("dl", true):
                if !openFolders.isEmpty {
                    openFolders.removeLast()
                }
            case ("h3", false):
                let name = scanner.readText(until: "h3")
                let isToolbar = tag["personal_toolbar_folder"] == "true"
                    || BookmarkImportRules.isToolbarName(name)
                pendingFolder = (name, isToolbar)
            case ("a", false):
                let title = scanner.readText(until: "a")
                guard let href = tag["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      BookmarkImportRules.isImportable(href)
                else { continue }
                let chain = openFolders.compactMap { entry in
                    entry.name.map { (name: $0, isToolbar: entry.isToolbar) }
                }
                results.append(ImportedBookmark(
                    title: title.isEmpty ? href : title,
                    urlString: href,
                    folderName: BookmarkImportRules.flattenedFolderName(chain: chain),
                    addedAt: date(fromAddDate: tag["add_date"])
                ))
            default:
                continue
            }
        }

        return results
    }

    /// Exports are UTF-8 in every browser shipping today, but files written years ago by
    /// Firefox or IE are Windows-1252 and `String(data:encoding:.utf8)` returns nil for
    /// them rather than mojibake. Falling back keeps those importable instead of showing
    /// an empty list.
    static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let cp1252 = String(data: data, encoding: .windowsCP1252) {
            return cp1252
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// `ADD_DATE` is whole seconds since 1970 in every export of this format. Chrome's
    /// *internal* bookmark store counts microseconds since 1601 and files hand-converted
    /// from it turn up with those numbers; a bookmark dated year 15000 is worse than a
    /// bookmark with no date, so anything implausible is dropped.
    static func date(fromAddDate raw: String?) -> Date? {
        guard let raw,
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds > 0,
              seconds < 100_000_000_000
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: Export

    /// Writes the file Chrome, Firefox, Edge and Safari all accept on import.
    ///
    /// Bar rows go inside a `PERSONAL_TOOLBAR_FOLDER` heading so they land on the other
    /// browser's bookmarks bar rather than in its "other bookmarks" drawer, and that is
    /// also what makes the round trip exact: `parse` reads a toolbar folder's direct
    /// children straight back out as bar rows.
    static func export(_ bookmarks: [ImportedBookmark], title: String = "Bookmarks") -> String {
        let barRows = bookmarks.filter { $0.folderName == nil }
        var folderOrder: [String] = []
        var grouped: [String: [ImportedBookmark]] = [:]
        for bookmark in bookmarks {
            guard let folder = bookmark.folderName else { continue }
            if grouped[folder] == nil {
                folderOrder.append(folder)
            }
            grouped[folder, default: []].append(bookmark)
        }

        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file. It will not be read by Aura. -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>\(escape(title))</TITLE>
        <H1>\(escape(title))</H1>
        <DL><p>

        """

        out += "    <DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks bar</H3>\n"
        out += "    <DL><p>\n"
        for bookmark in barRows {
            out += row(bookmark, indent: "        ")
        }
        out += "    </DL><p>\n"

        for folder in folderOrder {
            out += "    <DT><H3>\(escape(folder))</H3>\n"
            out += "    <DL><p>\n"
            for bookmark in grouped[folder] ?? [] {
                out += row(bookmark, indent: "        ")
            }
            out += "    </DL><p>\n"
        }

        out += "</DL><p>\n"
        return out
    }

    private static func row(_ bookmark: ImportedBookmark, indent: String) -> String {
        var attributes = "HREF=\"\(escape(bookmark.urlString))\""
        if let addedAt = bookmark.addedAt {
            attributes += " ADD_DATE=\"\(Int(addedAt.timeIntervalSince1970))\""
        }
        return "\(indent)<DT><A \(attributes)>\(escape(bookmark.title))</A>\n"
    }

    /// The five characters that would otherwise re-open a tag or an attribute. Ampersand
    /// goes first or it would double-escape the replacements that follow it.
    static func escape(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        return escaped.replacingOccurrences(of: "'", with: "&#39;")
    }
}

// MARK: - Scanner

/// A tag and its attributes, names lower-cased so `<A HREF>` and `<a href>` read alike.
private struct ScannedTag {
    var name: String
    var isClosing: Bool
    var attributes: [String: String]

    subscript(key: String) -> String? {
        attributes[key]
    }
}

/// Walks the file looking only for the four tags the format uses to mean something.
/// Everything else, including the malformed markup real exports are full of, is skipped
/// as text.
private struct TagScanner {
    private let text: String
    private var index: String.Index

    init(_ text: String) {
        self.text = text
        index = text.startIndex
    }

    mutating func nextTag() -> ScannedTag? {
        while index < text.endIndex {
            guard let open = text[index...].firstIndex(of: "<") else {
                index = text.endIndex
                return nil
            }
            index = text.index(after: open)
            guard index < text.endIndex else { return nil }

            // `<!DOCTYPE …>` and `<!-- … -->`: neither carries a bookmark.
            if text[index] == "!" {
                skipDeclaration()
                continue
            }

            var isClosing = false
            if text[index] == "/" {
                isClosing = true
                index = text.index(after: index)
            }

            let name = readName()
            if name.isEmpty {
                continue
            }
            let attributes = readAttributes()
            return ScannedTag(name: name, isClosing: isClosing, attributes: attributes)
        }
        return nil
    }

    /// The text between an opening tag and its close, entity-decoded, with any markup
    /// that snuck inside dropped. Titles carrying a stray `<b>` are common enough in
    /// hand-edited files that keeping the tag in the title would be visible.
    mutating func readText(until closingName: String) -> String {
        var out = ""
        while index < text.endIndex {
            guard let open = text[index...].firstIndex(of: "<") else {
                out += text[index...]
                index = text.endIndex
                break
            }
            out += text[index ..< open]
            let afterOpen = text.index(after: open)
            index = afterOpen
            guard afterOpen < text.endIndex else { break }

            var isClosing = false
            var cursor = afterOpen
            if text[cursor] == "/" {
                isClosing = true
                cursor = text.index(after: cursor)
            }
            index = cursor
            let name = readName()
            _ = readAttributes()
            if isClosing, name == closingName {
                break
            }
        }
        return decodeEntities(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func skipDeclaration() {
        if text[index...].hasPrefix("!--") {
            if let end = text.range(of: "-->", range: index ..< text.endIndex) {
                index = end.upperBound
                return
            }
            index = text.endIndex
            return
        }
        if let end = text[index...].firstIndex(of: ">") {
            index = text.index(after: end)
        } else {
            index = text.endIndex
        }
    }

    private mutating func readName() -> String {
        var name = ""
        while index < text.endIndex, text[index].isLetter || text[index].isNumber {
            name.append(text[index])
            index = text.index(after: index)
        }
        return name.lowercased()
    }

    /// Reads to the end of the tag. Values may be double-quoted, single-quoted or bare;
    /// Firefox writes base64 `ICON="data:…"` values that are longer than the rest of the
    /// line, so the quoted branch has to run to the closing quote and not to the first
    /// `>` it meets.
    private mutating func readAttributes() -> [String: String] {
        var attributes: [String: String] = [:]
        while index < text.endIndex {
            skipWhitespace()
            guard index < text.endIndex else { break }
            if text[index] == ">" {
                index = text.index(after: index)
                break
            }
            if text[index] == "/" {
                index = text.index(after: index)
                continue
            }

            var key = ""
            while index < text.endIndex,
                  !text[index].isWhitespace,
                  text[index] != "=",
                  text[index] != ">" {
                key.append(text[index])
                index = text.index(after: index)
            }
            skipWhitespace()

            var value = ""
            if index < text.endIndex, text[index] == "=" {
                index = text.index(after: index)
                skipWhitespace()
                value = readAttributeValue()
            }

            if !key.isEmpty {
                attributes[key.lowercased()] = decodeEntities(value)
            }
        }
        return attributes
    }

    /// The value after an `=`. Quoted runs to the closing quote, which is what keeps a
    /// base64 `ICON="data:…"` value from ending the tag early; bare runs to the next
    /// space or `>`, which is how the oldest exports write `HREF`.
    private mutating func readAttributeValue() -> String {
        var value = ""
        if index < text.endIndex, text[index] == "\"" || text[index] == "'" {
            let quote = text[index]
            index = text.index(after: index)
            while index < text.endIndex, text[index] != quote {
                value.append(text[index])
                index = text.index(after: index)
            }
            if index < text.endIndex {
                index = text.index(after: index)
            }
            return value
        }
        while index < text.endIndex, !text[index].isWhitespace, text[index] != ">" {
            value.append(text[index])
            index = text.index(after: index)
        }
        return value
    }

    private mutating func skipWhitespace() {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }
}

/// The handful of entities an export actually contains, plus numeric escapes.
///
/// Not `NSAttributedString`'s HTML reader: that one is main-thread-only, runs WebKit to
/// do it, and would turn decoding a bookmark title into a document load.
private func decodeEntities(_ value: String) -> String {
    guard value.contains("&") else { return value }
    let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"
    ]

    var out = ""
    var rest = Substring(value)
    while let start = rest.firstIndex(of: "&") {
        out += rest[..<start]
        let afterAmp = rest.index(after: start)
        // An entity longer than this is not one; `&` on its own is legal text.
        let window = rest[afterAmp...].prefix(12)
        guard let semicolon = window.firstIndex(of: ";") else {
            out.append("&")
            rest = rest[afterAmp...]
            continue
        }

        let body = rest[afterAmp ..< semicolon]
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let scalarValue: UInt32? = if digits.first == "x" || digits.first == "X" {
                UInt32(digits.dropFirst(), radix: 16)
            } else {
                UInt32(digits, radix: 10)
            }
            if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                out.unicodeScalars.append(scalar)
            }
        } else if let replacement = named[body.lowercased()] {
            out += replacement
        } else {
            // Unknown entity: kept verbatim rather than dropped, so a title reading
            // "R&D;" survives instead of becoming "R".
            out += rest[start ... semicolon]
        }
        rest = rest[rest.index(after: semicolon)...]
    }
    out += rest
    return out
}
