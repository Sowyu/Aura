import Foundation

/// `~/Library/Safari/Bookmarks.plist`.
///
/// A plain property list, despite what the file's age suggests: `Children` arrays of
/// dictionaries tagged `WebBookmarkTypeList` or `WebBookmarkTypeLeaf`, read with
/// `PropertyListSerialization`. It is not an `NSKeyedArchiver` archive, and unarchiving
/// it returns nil rather than failing loudly, which is the trap this parser exists to
/// stay out of.
///
/// Aura never reads the file itself: the app is sandboxed, `~/Library/Safari` is behind
/// full-disk access, and the only path that works is the user pointing an `NSOpenPanel`
/// at it. This function takes the bytes that panel produced and nothing else.
enum SafariBookmarks {
    /// Safari's internal names for the two lists it always has. Shown as-is they read
    /// like a bug report.
    private static let displayNames = [
        "BookmarksBar": "Bookmarks Bar",
        "BookmarksMenu": "Bookmarks Menu"
    ]
    private static let readingListTitle = "com.apple.ReadingList"
    /// Aura's reading list is a folder with a flag, and this is the name the import
    /// service matches to route Safari's articles into it.
    static let readingListFolderName = "Reading List"

    /// A file this deep is not a bookmark tree. Bounds the walk on input the user picked
    /// but did not write.
    private static let maxDepth = 24

    static func parse(_ data: Data) -> [ImportedBookmark] {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else { return [] }

        var results: [ImportedBookmark] = []
        for child in root["Children"] as? [[String: Any]] ?? [] {
            collectTopLevel(child, into: &results)
        }
        return results
    }

    /// The root's own children decide the one folder level Aura keeps: the bar becomes
    /// the bar, the reading list becomes the reading list, and every other list becomes
    /// a folder that absorbs whatever is nested inside it.
    private static func collectTopLevel(_ node: [String: Any], into results: inout [ImportedBookmark]) {
        switch node["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf":
            if let leaf = leaf(node, folderName: nil) {
                results.append(leaf)
            }
        case "WebBookmarkTypeList":
            let title = node["Title"] as? String ?? ""
            if title == readingListTitle {
                collect(node, folderName: readingListFolderName, depth: 0, into: &results)
                return
            }
            if BookmarkImportRules.isToolbarName(title) || displayNames[title] == "Bookmarks Bar" {
                collectToolbar(node, into: &results)
                return
            }
            collect(node, folderName: displayNames[title] ?? title, depth: 0, into: &results)
        default:
            // `WebBookmarkTypeProxy` is History and the like: a placeholder, not a page.
            return
        }
    }

    private static func collectToolbar(_ node: [String: Any], into results: inout [ImportedBookmark]) {
        for child in node["Children"] as? [[String: Any]] ?? [] {
            switch child["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                if let leaf = leaf(child, folderName: nil) {
                    results.append(leaf)
                }
            case "WebBookmarkTypeList":
                let title = child["Title"] as? String ?? ""
                collect(child, folderName: displayNames[title] ?? title, depth: 0, into: &results)
            default:
                continue
            }
        }
    }

    /// Everything under `node`, however deep, filed under the one folder name.
    private static func collect(
        _ node: [String: Any],
        folderName: String?,
        depth: Int,
        into results: inout [ImportedBookmark]
    ) {
        guard depth < maxDepth else { return }
        for child in node["Children"] as? [[String: Any]] ?? [] {
            switch child["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                if let leaf = leaf(child, folderName: folderName) {
                    results.append(leaf)
                }
            case "WebBookmarkTypeList":
                collect(child, folderName: folderName, depth: depth + 1, into: &results)
            default:
                continue
            }
        }
    }

    private static func leaf(_ node: [String: Any], folderName: String?) -> ImportedBookmark? {
        guard let urlString = node["URLString"] as? String,
              BookmarkImportRules.isImportable(urlString)
        else { return nil }
        let uriTitle = (node["URIDictionary"] as? [String: Any])?["title"] as? String
        let title = uriTitle ?? node["Title"] as? String ?? urlString
        let addedAt = (node["ReadingList"] as? [String: Any])?["DateAdded"] as? Date
        return ImportedBookmark(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            urlString: urlString,
            folderName: folderName,
            addedAt: addedAt
        )
    }
}
