import AppKit
import Foundation
@preconcurrency import WebKit

/// Copy-to-clipboard inside an extension popup.
///
/// A popup web view is not a page the user granted anything to, so WebKit denies
/// `navigator.clipboard.writeText` and `document.execCommand('copy')` there outright.
/// Password managers, note clippers and colour pickers all copy from their popup, and
/// from the user's side the button simply does nothing. This routes those calls to
/// `NSPasteboard` through a message handler on the popup's own content controller, so no
/// ordinary web page ever sees the override.
///
/// Ported from Nook, `Nook/Managers/ExtensionManager/PopupUIDelegate.swift` by
/// Maciek Bagiński (GPL-3.0).
final class ExtensionPopupClipboard: NSObject, WKScriptMessageHandler {
    static let handlerName = "auraExtensionClipboard"

    /// One handler for every popup: it holds no per-popup state, and the content
    /// controller would otherwise keep a new object alive per extension.
    static let shared = ExtensionPopupClipboard()

    /// Web views the user script is already on. Weak, and only ever consulted: WebKit
    /// usually builds a fresh popup web view per present, but when it reuses one the
    /// script would otherwise be added again on every click.
    private let installed = NSHashTable<WKWebView>.weakObjects()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Registers the bridge and injects the polyfill into the popup that is about to
    /// show. Called on every present: WebKit builds a fresh popup web view each time.
    static func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: handlerName)
        controller.add(shared, name: handlerName)

        if !shared.installed.contains(webView) {
            shared.installed.add(webView)
            controller.addUserScript(WKUserScript(
                source: polyfillSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
        // The popup's document is usually already loaded by the time WebKit asks us to
        // present it, and a user script only runs on the next document.
        webView.evaluateJavaScript(polyfillSource, completionHandler: nil)
    }

    static let polyfillSource = """
    (function() {
        if (window.__auraClipboardInstalled) return;
        window.__auraClipboardInstalled = true;

        var handlers = window.webkit && window.webkit.messageHandlers;
        var bridge = handlers && handlers.\(handlerName);
        if (!bridge) return;

        function copy(text) {
            if (!text) return false;
            try { bridge.postMessage(String(text)); return true; } catch (e) { return false; }
        }

        function selectedText() {
            var el = document.activeElement;
            if (el && (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') && typeof el.value === 'string') {
                return el.value.substring(el.selectionStart, el.selectionEnd) || el.value;
            }
            var selection = window.getSelection();
            return selection ? selection.toString() : '';
        }

        if (navigator.clipboard) {
            var originalWrite = navigator.clipboard.writeText;
            navigator.clipboard.writeText = function(text) {
                if (copy(text)) return Promise.resolve();
                return originalWrite
                    ? originalWrite.call(navigator.clipboard, text)
                    : Promise.reject(new Error('clipboard unavailable'));
            };
        }

        var originalExec = document.execCommand.bind(document);
        document.execCommand = function(command) {
            if ((command === 'copy' || command === 'cut') && copy(selectedText())) return true;
            return originalExec.apply(document, arguments);
        };

        document.addEventListener('copy', function() { copy(selectedText()); }, true);
    })();
    """
}
