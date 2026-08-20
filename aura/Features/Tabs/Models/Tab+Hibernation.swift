import AppKit
import Foundation

// MARK: - Hibernation

extension Tab {
    /// Asked once, only when a tab is about to be unloaded, so live pages pay nothing
    /// for it. Reports whether the user has typing in progress (which vetoes the unload)
    /// and stashes the scroll offset to restore on the way back.
    func captureHibernationState(completion: @escaping (Bool) -> Void) {
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
            completion(fields["dirty"] as? Bool ?? false)
        }
    }

    /// Re-applies the offset the tab was unloaded at, once, and only if the page that
    /// came back is the page that went away.
    func restoreScrollOffsetIfNeeded() {
        guard let offset = hibernatedScrollOffset, hibernatedScrollURL == url else { return }
        hibernatedScrollOffset = nil
        hibernatedScrollURL = nil
        guard offset != .zero else { return }
        evaluateJavaScript("window.scrollTo(\(offset.x), \(offset.y));")
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
