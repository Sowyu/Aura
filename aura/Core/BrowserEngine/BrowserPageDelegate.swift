import AppKit
import Foundation

protocol BrowserPageDelegate: AnyObject {
    func browserPage(
        _ page: BrowserPage,
        decidePolicyFor navigationAction: BrowserNavigationAction
    ) -> BrowserNavigationActionDisposition
    func browserPage(_ page: BrowserPage, didRequestOpenInNewTab url: URL)
    /// A `window.open()` popup, already built on the configuration WebKit demanded so
    /// that `window.opener` survives. Return true once it is hosted in a tab; false
    /// makes the page fall back to `didRequestOpenInNewTab`, which loses the opener.
    func browserPage(_ page: BrowserPage, didRequestAdopt popup: BrowserPage, for url: URL?) -> Bool
    func browserPage(_ page: BrowserPage, didUpdateNavigation event: BrowserNavigationEvent)
    func browserPage(_ page: BrowserPage, didFailNavigationWith error: Error, failingURL: URL?)
    func browserPage(_ page: BrowserPage, didReceiveScriptMessage message: BrowserScriptMessage)
    func browserPage(
        _ page: BrowserPage,
        requestPermission permission: BrowserPermissionKind,
        origin: URL?,
        decisionHandler: @escaping (BrowserPermissionDecision) -> Void
    )
    func browserPage(
        _ page: BrowserPage,
        runOpenPanelWith options: BrowserOpenPanelOptions,
        completion: @escaping ([URL]?) -> Void
    )
    func browserPage(_ page: BrowserPage, runJavaScriptAlert message: String, completion: @escaping () -> Void)
    func browserPage(_ page: BrowserPage, runJavaScriptConfirm message: String, completion: @escaping (Bool) -> Void)
    func browserPage(
        _ page: BrowserPage,
        runJavaScriptPrompt prompt: String,
        defaultText: String?,
        completion: @escaping (String?) -> Void
    )
    func browserPage(_ page: BrowserPage, didStartDownload download: BrowserDownloadTask)
    /// `location` is in window coordinates. `inspectElement` is nil when WebKit offered no
    /// inspector item, which is the case while developer extras are off.
    func browserPage(
        _ page: BrowserPage,
        didRequestContextMenu info: BrowserContextMenuInfo,
        at location: CGPoint,
        inspectElement: (() -> Void)?
    )
}

extension BrowserPageDelegate {
    func browserPage(
        _ page: BrowserPage,
        decidePolicyFor navigationAction: BrowserNavigationAction
    ) -> BrowserNavigationActionDisposition {
        .allow
    }

    func browserPage(_ page: BrowserPage, didRequestOpenInNewTab url: URL) {}

    func browserPage(_ page: BrowserPage, didRequestAdopt popup: BrowserPage, for url: URL?) -> Bool {
        false
    }

    func browserPage(_ page: BrowserPage, didUpdateNavigation event: BrowserNavigationEvent) {}

    func browserPage(_ page: BrowserPage, didFailNavigationWith error: Error, failingURL: URL?) {}

    func browserPage(_ page: BrowserPage, didReceiveScriptMessage message: BrowserScriptMessage) {}

    func browserPage(
        _ page: BrowserPage,
        requestPermission permission: BrowserPermissionKind,
        origin: URL?,
        decisionHandler: @escaping (BrowserPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    func browserPage(
        _ page: BrowserPage,
        runOpenPanelWith options: BrowserOpenPanelOptions,
        completion: @escaping ([URL]?) -> Void
    ) {
        completion(nil)
    }

    func browserPage(_ page: BrowserPage, runJavaScriptAlert message: String, completion: @escaping () -> Void) {
        completion()
    }

    func browserPage(_ page: BrowserPage, runJavaScriptConfirm message: String, completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func browserPage(
        _ page: BrowserPage,
        runJavaScriptPrompt prompt: String,
        defaultText: String?,
        completion: @escaping (String?) -> Void
    ) {
        completion(nil)
    }

    func browserPage(_ page: BrowserPage, didStartDownload download: BrowserDownloadTask) {}

    func browserPage(
        _ page: BrowserPage,
        didRequestContextMenu info: BrowserContextMenuInfo,
        at location: CGPoint,
        inspectElement: (() -> Void)?
    ) {}
}
