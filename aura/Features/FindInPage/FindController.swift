import Foundation
@preconcurrency import WebKit

/// Find in page, on WebKit's own search rather than a DOM walker.
///
/// `WKWebView.find(_:configuration:)` (macOS 11.3+) is the same code path Safari's find
/// bar uses: it searches rendered text, so it sees shadow DOM, `<iframe>` content and
/// text a CSS transform moved, and it selects and scrolls to each hit without rewriting
/// the page. The mark.js injection this replaces wrapped every hit in a `<mark>` element,
/// which mutated the live DOM of whatever the user was reading and lost every match
/// inside an iframe or a shadow root.
///
/// What is gone with it: `WKFindResult` reports only whether a match was found, with no
/// index and no total, so there is no "3 / 17". Safari shows no counter either.
final class FindController {
    private weak var page: BrowserPage?

    init(page: BrowserPage) {
        self.page = page
    }

    /// Searches from the current match, wrapping at the end of the document, and reports
    /// on the main queue whether anything matched.
    func find(_ term: String, forward: Bool = true, completion: @escaping (Bool) -> Void) {
        guard let page, !term.isEmpty else {
            completion(false)
            return
        }

        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true

        page.auraWebView.find(term, configuration: configuration) { result in
            let matchFound = result.matchFound
            DispatchQueue.main.async { completion(matchFound) }
        }
    }

    /// Drops the highlight the last search left behind.
    ///
    /// ponytail: WebKit exposes no public call to hide its find highlight (Safari uses
    /// `_hideFindUI`), and the highlight *is* the document selection, so clearing the
    /// selection clears it. Swap this for the real call if it ever ships.
    func clear() {
        page?.evaluateJavaScript("window.getSelection() && window.getSelection().removeAllRanges();")
    }
}
