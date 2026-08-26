import SwiftUI

struct BrowserWebContentView: View {
    @Environment(\.theme) var theme
    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(DialogManager.self) private var dialogManager
    @Environment(AppState.self) private var appState
    @Environment(ToolbarManager.self) private var toolbarManager
    let tab: Tab

    /// The file this view has already put a consent dialog up for.
    @State private var consentPrompt: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            webContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .auraDropTarget(handleDrop)
        // `task(id:)` rather than `onChange`: a request can be waiting before this view is
        // ever mounted (a file opened straight into a new tab), and `onChange` only fires
        // for a value that moves while the view is on screen. The state below is what
        // stops a tab switch away and back from putting a second dialog on the stack.
        .task(id: FileOpenService.shared.consentRequest(forTab: tab.id)) {
            let request = FileOpenService.shared.consentRequest(forTab: tab.id)
            guard consentPrompt != request else { return }
            consentPrompt = request
            guard let request else { return }
            presentConsent(for: request)
        }
    }

    // MARK: - Drops

    /// A drop on the page navigates this tab. WebKit is asked first, so a page with its
    /// own drop handling keeps it; what arrives here is what WebKit turned down.
    private func handleDrop(_ payload: DropPayload) -> Bool {
        switch payload {
        case .tabItem, .nothing:
            // A sidebar row being dragged is the tab machinery's business, not a page's.
            return false
        case let .files(urls):
            // The drop is the grant. Writing it down now is what lets the tray reopen the
            // file after a relaunch, when the drag is long over.
            FileOpenService.shared.rememberGrants(for: urls)
            guard let first = urls.first else { return false }
            tab.loadURL(first.absoluteString)
            for extra in urls.dropFirst() {
                openInNewTab(extra)
            }
            return true
        case let .url(url):
            tab.loadURL(url.absoluteString)
            return true
        case let .search(text):
            // `loadURL` searches for anything that is not an address, with the space's own
            // engine, which is what the address field does with the same text.
            tab.loadURL(text)
            return true
        }
    }

    private func openInNewTab(_ url: URL) {
        tabManager.openTab(
            url: url,
            historyManager: historyManager,
            downloadManager: downloadManager,
            focusAfterOpening: false,
            isPrivate: tab.isPrivate
        )
    }

    // MARK: - File consent

    /// A path typed into the address field has no sandbox grant behind it, so the tab asks
    /// before it navigates. The dialog explains; the panel behind it is the only thing
    /// macOS accepts as consent.
    private func presentConsent(for url: URL) {
        dialogManager.confirm(
            title: FileOpenService.consentTitle(for: url),
            message: FileOpenService.consentMessage,
            iconImage: Image(systemName: "doc.text"),
            confirmLabel: "Choose File",
            onConfirm: {
                guard let granted = FileOpenService.shared.confirmConsent(forTab: tab.id) else { return }
                tab.loadURL(granted.absoluteString)
            },
            onCancel: { FileOpenService.shared.cancelConsent(forTab: tab.id) }
        )
    }

    @ViewBuilder
    private var webContent: some View {
        if tab.url.isOraHome {
            HomePageView(tab: tab)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if tab.url.isOraExtensions {
            ExtensionStoreView()
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if tab.url.isOraViewSource {
            ViewSourceView(tab: tab)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if tab.url.isOraReader {
            ReaderView(tab: tab)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if tab.url.isOraSettings {
            SettingsContentView(initialTab: tab.url.oraSettingsSection)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if tab.isWebViewReady {
            if tab.hasNavigationError, let error = tab.navigationError {
                StatusPageView(
                    error: error,
                    failedURL: tab.failedURL,
                    onRetry: { tab.retryNavigation() },
                    onGoBack: tab.canGoBack
                        ? {
                            tab.goBack()
                            tab.clearNavigationError()
                        } : nil,
                    onContinueAnyway: {
                        tab.continueToInsecureSite()
                    }
                )
                .id(tab.id)
            } else if let page = tab.browserPage {
                BrowserPageView(page: page).id(tab.id)
                    .overlay(alignment: .topLeading) {
                        if let triggerState = tab.passwordTriggerOverlayState {
                            PasswordAutofillTriggerView(overlay: triggerState, tab: tab)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let passwordOverlayState = tab.passwordOverlayState {
                            PasswordAutofillOverlayView(overlay: passwordOverlayState, tab: tab)
                        }
                    }
                    // Top centre, not the leading corner the two password prompts share:
                    // a camera request arriving mid-login would otherwise cover the
                    // "save this password?" prompt it is stacked on.
                    .overlay(alignment: .top) {
                        // Keyed on the request so a second prompt starts with its own
                        // "remember" state rather than the last one's.
                        if let request = SitePermissionCoordinator.shared.request(forTab: tab.id) {
                            SitePermissionPromptView(request: request)
                                .id(request.id)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let hovered = tab.hoveredLinkURL, !hovered.isEmpty {
                            LinkPreview(text: hovered)
                        }
                    }
            } else {
                ZStack {
                    Rectangle().fill(theme.background)
                    ProgressView().frame(width: 32, height: 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ZStack {
                Rectangle().fill(theme.background)
                ProgressView().frame(width: 32, height: 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
