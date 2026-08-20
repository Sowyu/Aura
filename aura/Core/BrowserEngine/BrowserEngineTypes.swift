import AppKit
import Foundation

enum BrowserWebsiteDataType: Hashable {
    case cookies
    case cache
    case all
}

enum BrowserUserScriptInjectionTime {
    case atDocumentStart
    case atDocumentEnd
}

struct BrowserUserScript {
    let name: String?
    let source: String
    let injectionTime: BrowserUserScriptInjectionTime
    let forMainFrameOnly: Bool
}

struct BrowserScriptMessage {
    let name: String
    let body: Any?
}

struct BrowserOpenPanelOptions {
    let allowsDirectories: Bool
    let allowsMultipleSelection: Bool
}

enum BrowserPermissionKind {
    case mediaCapture
}

enum BrowserPermissionDecision {
    case grant
    case deny
    case prompt
}

struct BrowserNavigationAction {
    let request: URLRequest
    let modifierFlags: NSEvent.ModifierFlags
    /// A nil target frame means a brand-new frame or window, which counts as main frame.
    var isMainFrame = true
    /// True for a link click or a form submission, as opposed to a redirect or a reload.
    var isUserInitiated = false
}

enum BrowserNavigationActionDisposition {
    case allow
    case cancel
    case openInNewTab
}

enum BrowserNavigationPhase {
    case started
    case committed
    case finished
}

struct BrowserNavigationEvent {
    let phase: BrowserNavigationPhase
    let url: URL?
    let title: String?
    let progress: Double
    let isLoading: Bool
}

struct BrowserSnapshotConfiguration {
    let rect: CGRect?
    let afterScreenUpdates: Bool

    static let full = BrowserSnapshotConfiguration(rect: nil, afterScreenUpdates: false)
}

/// What sat under the pointer when the page's context menu was asked for. Filled by the
/// page-side `contextmenu` listener, which runs before AppKit builds its own menu.
struct BrowserContextMenuInfo {
    var link: URL?
    var linkText: String?
    var image: URL?
    var media: URL?
    var selection: String?
    var isEditable = false

    var hasSelection: Bool {
        !(selection ?? "").isEmpty
    }
}
