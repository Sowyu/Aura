import AppKit
import Foundation

// MARK: - Hibernation

extension Tab {
    /// Asked once, only when a tab is about to be unloaded, so live pages pay nothing
    /// for it. Reports whether the user has typing in progress (which vetoes the unload)
    /// and stashes the scroll offset to restore on the way back.
    func captureHibernationState(completion: @escaping (Bool) -> Void) {
        if let unsavedInputProbe {
            unsavedInputProbe(completion)
            return
        }
        guard let page = browserPage else {
            completion(false)
            return
        }
        page.evaluateJavaScript(Tab.hibernationProbe) { [weak self] result, error in
            guard let self,
                  error == nil,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // The page could not be asked, so assume it has something to lose and
                // leave it alone. The next maintenance pass asks again.
                completion(true)
                return
            }
            let offset = CGPoint(
                x: fields["x"] as? Double ?? 0,
                y: fields["y"] as? Double ?? 0
            )
            if offset != .zero {
                self.hibernatedScrollOffset = offset
                self.hibernatedScrollURL = self.url
            }
            // The web view is about to go, and with it the only live copy of the back
            // list. Writing it here is also what carries the offset across a relaunch:
            // the transient pair above dies with the process.
            MainActor.assumeIsolated {
                guard let store = self.tabManager?.sessionStore else { return }
                if store.capture(self, scroll: offset, scrollURL: self.url) { store.save() }
            }
            completion(fields["dirty"] as? Bool ?? false)
        }
    }

    /// Re-applies the offset the tab was unloaded at, once, and only if the page that
    /// came back is the page that went away. After a relaunch there is no transient
    /// offset left, so the saved one stands in for it.
    ///
    /// The test runs in the page rather than here, because WebKit usually gets there
    /// first: a restored session blob carries the current item's scroll position and puts
    /// the page back on its own (measured on macOS 27: a view restored from a blob taken
    /// at scrollY 1234 came back at 1234). It lands whenever WebKit's layout says so, so
    /// whichever of the two is second must not yank the page away from where the user
    /// already is.
    func restoreScrollOffsetIfNeeded() {
        guard let offset = takePendingScrollOffset(), offset != .zero else { return }
        evaluateJavaScript(
            """
            if ((window.scrollY || 0) < 1 && (window.scrollX || 0) < 1) {
                window.scrollTo(\(offset.x), \(offset.y));
            }
            """
        )
    }

    /// The offset waiting for the page now on screen, consumed on read. The one stashed
    /// on the way into hibernation wins: it is newer than anything on disk.
    private func takePendingScrollOffset() -> CGPoint? {
        if let offset = hibernatedScrollOffset, hibernatedScrollURL == url {
            hibernatedScrollOffset = nil
            hibernatedScrollURL = nil
            return offset
        }
        guard !didOfferSavedScroll else { return nil }
        didOfferSavedScroll = true
        return MainActor.assumeIsolated { () -> CGPoint? in
            guard let session = tabManager?.sessionStore.session(for: id),
                  session.scrollURLString == url.absoluteString
            else {
                return nil
            }
            return session.scrollOffset
        }
    }
}

private extension Tab {
    /// Reports unsaved typing and the scroll offset in one round trip. `defaultValue`
    /// is the markup's value, so a field the user never touched reads as clean even
    /// when it was server-rendered with content.
    static let hibernationProbe = """
    (function () {
        function isDirty() {
            var nodes = document.querySelectorAll('input, textarea, [contenteditable]');
            for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                if (el.isContentEditable) {
                    if ((el.textContent || '').trim() !== '') return true;
                    continue;
                }
                var type = (el.type || '').toLowerCase();
                if (type === 'hidden' || type === 'submit' || type === 'button' || type === 'reset') {
                    continue;
                }
                if (type === 'checkbox' || type === 'radio') {
                    if (el.checked !== el.defaultChecked) return true;
                    continue;
                }
                if ((el.value || '') !== (el.defaultValue || '')) return true;
            }
            return false;
        }
        var dirty = false;
        try { dirty = isDirty(); } catch (error) {}
        return JSON.stringify({
            dirty: dirty,
            x: window.scrollX || 0,
            y: window.scrollY || 0
        });
    })();
    """
}
