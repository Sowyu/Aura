import AppKit
import SwiftUI

/// Address field shared by the top toolbar and the floating URL bar.
/// Shows the current URL and morphs into the inline launcher while editing.
struct URLBarField: View {
    /// `nil` while no tab is active; the field still renders as an empty pill.
    let tab: Tab?
    /// Muted colour used for icons and secondary text.
    let foregroundColor: Color
    /// Full-strength colour used for typed text and the caret. Also drives the
    /// pill fill, so callers must pass an undimmed colour.
    let textColor: Color

    @Environment(TabManager.self) private var tabManager
    @Environment(AppState.self) private var appState
    @Environment(ToolbarManager.self) private var toolbarManager
    @Environment(ToastManager.self) private var toastManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @EnvironmentObject var privacyMode: PrivacyMode

    @Environment(\.theme) private var theme
    @Environment(\.window) private var window

    @State private var showCopiedAnimation = false
    @State private var startWheelAnimation = false

    // Inline launcher state
    @StateObject private var launcherViewModel = LauncherViewModel()
    @State private var launcherInput = ""
    @State private var mouseHasMoved = false
    @State private var mouseMonitor: Any?
    @State private var suppressInitialSearch = false
    /// Natural height of the suggestion list, measured so it can be capped to the window.
    @State private var suggestionsHeight: CGFloat = 0

    @State private var clickAwayMonitor: Any?
    /// Zero-sized AppKit view the site panel hangs under.
    @State private var siteInfoAnchor: NSView?

    private var isEditing: Bool {
        appState.isURLBarEditing
    }

    /// One pill for both modes so entering edit mode cannot change the height. The
    /// space colour stays on the sidebar rows' stripe; a permanent ring here read as
    /// the field being focused all the time.
    private var pill: some View {
        ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(textColor.opacity(0.08))
            .overlay(
                ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(textColor.opacity(0.06), lineWidth: 1)
            )
    }

    static let height: CGFloat = 30
    private static let cornerRadius: CGFloat = AuraRadius.row
    /// Field layout: leading padding, the security icon and the gap after it. The
    /// suggestion rows below are inset to put their titles on the same column.
    private static let leadingPadding: CGFloat = 8
    private static let iconWidth: CGFloat = 16
    private static let iconSpacing: CGFloat = 8
    private static let suggestionsPadding: CGFloat = 8
    static var textInset: CGFloat { leadingPadding + iconWidth + iconSpacing }
    /// Field height plus the gap, so the list clears the pill.
    private static let suggestionsGap: CGFloat = height + 8
    /// Below this the list is not worth showing downwards; flip it above the field.
    private static let suggestionsMinHeight: CGFloat = 160
    private static let windowInset: CGFloat = 12

    /// Space between the field and the window's edges. The list is anchored to the field
    /// and never wider than it, so only the vertical fit needs checking.
    private var suggestionsSpace: (above: CGFloat, below: CGFloat)? {
        guard let contentHeight = window?.contentView?.bounds.height, contentHeight > 0 else { return nil }
        let field = appState.urlFieldFrame
        guard !field.isEmpty else { return nil }
        return (
            above: field.minY - Self.suggestionsGap - Self.windowInset,
            below: contentHeight - field.maxY - Self.windowInset - (Self.suggestionsGap - Self.height)
        )
    }

    /// A floating URL bar near the bottom of the window would drop its list off-screen.
    private var suggestionsFlipUp: Bool {
        guard let space = suggestionsSpace else { return false }
        return space.below < Self.suggestionsMinHeight && space.above > space.below
    }

    private var suggestionsMaxHeight: CGFloat {
        guard let space = suggestionsSpace else { return .infinity }
        return max(Self.suggestionsMinHeight, suggestionsFlipUp ? space.above : space.below)
    }

    // MARK: - Body

    var body: some View {
        field
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { appState.urlFieldFrame = $0 }
            .overlay(alignment: suggestionsFlipUp ? .bottom : .top) {
                if isEditing {
                    suggestionsOverlay()
                        .offset(y: suggestionsFlipUp ? -Self.suggestionsGap : Self.suggestionsGap)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            // Only while the list is really up. The old `.onDisappear` ran a
                            // frame late and raced the transition, leaving a live hole punched
                            // in `BrowserView`'s backdrop over nothing.
                            appState.urlSuggestionsFrame = isEditing ? $0 : .zero
                        }
                        .transition(.move(edge: suggestionsFlipUp ? .bottom : .top).combined(with: .opacity))
                }
            }
            .animation(AnimationSettings.easeOut(0.15), value: isEditing)
            // Hidden button for the focus-address-bar shortcut. Hidden from assistive
            // technology too: it carries no label, and it is only here to own ⌘L.
            .overlay(
                Button("") { startEditing() }
                    .oraShortcut(KeyboardShortcuts.Address.focus)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
            // Clicking anywhere outside the field or its suggestions ends the edit, the way
            // every browser's address bar behaves; AppKit alone only does it when the click
            // lands on something that takes first responder.
            .onChange(of: isEditing, initial: true) { _, editing in
                if editing, clickAwayMonitor == nil {
                    clickAwayMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                        .leftMouseDown,
                        .rightMouseDown
                    ]) { event in
                        guard let window = event.window else { return event }
                        let height = window.contentView?.bounds.height ?? window.frame.height
                        let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
                        let inside = appState.urlFieldFrame.contains(point) || appState.urlSuggestionsFrame
                            .contains(point)
                        if !inside { DispatchQueue.main.async { dismissEditing() } }
                        return event
                    }
                } else if !editing, let monitor = clickAwayMonitor {
                    NSEvent.removeMonitor(monitor)
                    clickAwayMonitor = nil
                }
            }
            .onChange(of: isEditing) { _, editing in
                if editing {
                    setupInlineLauncher()
                } else {
                    cleanupInlineLauncher()
                }
            }
            .onChange(of: tabManager.activeTab?.id) { _, _ in
                if isEditing {
                    dismissEditing()
                }
            }
            .onChange(of: appState.showLauncher) { _, newValue in
                // Dismiss URL bar editing if the center launcher is opened
                if newValue, isEditing {
                    dismissEditing()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyAddressURL)) { _ in
                if let activeTab = tabManager.activeTab {
                    ClipboardUtils.copyWithToast(
                        activeTab.url.absoluteString,
                        toastManager: toastManager
                    )
                }
            }
    }

    // MARK: - Field

    /// One NSTextField for both modes. The field editor owns mouse tracking, so a
    /// drag selects text instead of moving the hidden-titlebar window.
    private var field: some View {
        HStack(spacing: Self.iconSpacing) {
            // The lock is the site panel's handle, the way it is in Safari and Chrome.
            // Left as a plain icon while editing or with no tab: there is no site to
            // describe, and a button that opens an empty menu is worse than no button.
            draggableAddress {
                Button {
                    siteInfoAnchor?.presentAuraMenu(SiteInfoMenu.items(for: tab, tabManager: tabManager))
                } label: {
                    iconContent
                        .frame(width: Self.iconWidth, height: Self.iconWidth)
                }
                .buttonStyle(.interactive(cornerRadius: 5, tint: foregroundColor))
                // On an `aura://` page `SiteInfoMenu` has nothing to say and answers with
                // one disabled row, and an empty menu is worse than no button.
                .disabled(tab == nil || isEditing || tab?.url.isOraInternal == true)
            }
            .background(AuraMenuAnchorView { siteInfoAnchor = $0 })
            .help("Site information")
            .accessibilityLabel(Text("Site information"))

            ZStack(alignment: .leading) {
                CopiedURLOverlay(
                    foregroundColor: foregroundColor,
                    showCopiedAnimation: $showCopiedAnimation,
                    startWheelAnimation: $startWheelAnimation
                )

                LauncherTextField(
                    text: $launcherInput,
                    font: NSFont.systemFont(ofSize: 14, weight: .regular),
                    onTab: {},
                    onSubmit: { launcherViewModel.executeCommand() },
                    onDelete: { false },
                    onMoveUp: { launcherViewModel.moveFocusedElement(.up) },
                    onMoveDown: { launcherViewModel.moveFocusedElement(.down) },
                    cursorColor: textColor.opacity(0.8),
                    textColor: isEditing ? textColor.opacity(0.7) : foregroundColor,
                    placeholder: "Search or enter address",
                    displayText: displayText,
                    isEditing: isEditing,
                    onBeginEditing: startEditing,
                    onEndEditing: dismissEditing,
                    onEscape: dismissEditing
                )

                // Single line: let the HStack centre it instead of filling the pill and drawing at the top.

                .fixedSize(horizontal: false, vertical: true)
                .opacity(showCopiedAnimation ? 0 : 1)
                .offset(y: showCopiedAnimation ? (startWheelAnimation ? -12 : 12) : 0)
                .animation(AnimationSettings.easeOut(0.15), value: showCopiedAnimation)
                .animation(AnimationSettings.easeOut(0.15), value: startWheelAnimation)
                .onChange(of: launcherInput) { _, newValue in
                    guard isEditing else { return }
                    launcherViewModel.currentText = newValue
                    guard !suppressInitialSearch else { return }
                    launcherViewModel.searchHandler(newValue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isEditing {
                SiteZoomBadge(tab: tab, foregroundColor: foregroundColor)
            }

            Button {
                if let activeTab = tabManager.activeTab {
                    ClipboardUtils.triggerCopy(
                        activeTab.url.absoluteString,
                        showCopiedAnimation: $showCopiedAnimation,
                        startWheelAnimation: $startWheelAnimation
                    )
                }
            } label: {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(foregroundColor)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.interactive(cornerRadius: 6, tint: foregroundColor))
            .disabled(tab == nil || isEditing)
            .opacity(tab == nil || isEditing ? 0 : 1)
            .oraShortcutHelp("Copy URL", for: KeyboardShortcuts.Address.copyURL)
            .accessibilityLabel(Text("Copy URL"))
        }
        .frame(height: Self.height)
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, 4)
        .background(pill)
    }

    /// The leading icon is the page's handle: dragging it carries the address, the way
    /// Safari's and Chrome's do, which is how a page reaches the bookmarks bar without
    /// going through a menu. Internal pages and an empty field have nothing to hand over,
    /// so they stay a plain icon rather than starting a drag that drops nothing.
    ///
    /// The drag sits on the button, not inside its label: a `.draggable` in the label is
    /// under the button's own gesture, which claims the press first.
    @ViewBuilder
    private func draggableAddress(@ViewBuilder _ content: () -> some View) -> some View {
        if let url = tab?.url, !url.isOraInternal, !isEditing {
            content().draggable(url)
        } else {
            content()
        }
    }

    private var iconContent: some View {
        ZStack {
            if tab?.isLoading == true, !isEditing {
                ProgressView()
                    .tint(foregroundColor)
                    .scaleEffect(0.5)
            } else {
                Image(systemName: isEditing ? editingSymbol : securitySymbol)
                    .font(.system(size: 12))
                    .foregroundColor(foregroundColor)
            }
        }
        .contentShape(Rectangle())
    }

    private var securitySymbol: String {
        guard let tab else { return "magnifyingglass" }
        return tab.url.scheme == "https" ? "shield.lefthalf.filled" : "globe"
    }

    private var editingSymbol: String {
        isValidURL(launcherInput) ? "globe" : "magnifyingglass"
    }

    private var displayText: String {
        guard let tab else { return "" }
        return URLDisplayUtils.displayString(url: tab.url, title: tab.title, showFull: toolbarManager.showFullURL)
    }

    // MARK: - Suggestions Overlay

    private var suggestionRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(launcherViewModel.suggestions) { suggestion in
                LauncherSuggestionItem(
                    suggestion: suggestion,
                    focusedElement: $launcherViewModel.focusedElement,
                    leadingInset: LauncherRowMetrics.leadingInset(
                        textInset: Self.textInset,
                        panelPadding: Self.suggestionsPadding,
                        iconWidth: Self.iconWidth
                    ),
                    iconWidth: Self.iconWidth
                )
            }
        }
        .padding(Self.suggestionsPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { suggestionsHeight = $0 }
    }

    @ViewBuilder
    private func suggestionsOverlay() -> some View {
        if !launcherViewModel.suggestions.isEmpty {
            Group {
                // Measured first, scrolled only once it does not fit: a `ScrollView` takes
                // every point offered, so it cannot size itself to a short list.
                if suggestionsHeight > suggestionsMaxHeight {
                    ScrollView(.vertical) { suggestionRows }
                        .frame(height: suggestionsMaxHeight)
                } else {
                    suggestionRows
                }
            }
            .background(theme.launcherMainBackground)
            .background(BlurEffectView(material: .popover, blendingMode: .withinWindow))
            .clipShape(ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay(
                ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
                    .padding(0.25)
            )
            .auraFloatingShadow()
            .environment(\.launcherMouseHasMoved, mouseHasMoved)
        }
    }
}

// MARK: - Inline launcher

extension URLBarField {
    /// Called from the shortcut and from the text field becoming first responder.
    private func startEditing() {
        guard !isEditing else { return }
        // Pre-fill before flipping the flag so the field edits the URL, not the host.
        suppressInitialSearch = true
        launcherInput = tabManager.activeTab?.url.absoluteString ?? ""
        withAnimation(AnimationSettings.easeOut(0.1)) {
            appState.isURLBarEditing = true
        }
    }

    private func setupInlineLauncher() {
        suppressInitialSearch = true
        launcherViewModel.searchEngineService.setTheme(theme)
        launcherViewModel.configure(
            tabManager: tabManager,
            historyManager: historyManager,
            downloadManager: downloadManager,
            appState: appState,
            privacyMode: privacyMode,
            onSubmit: onLauncherSubmit,
            onDismiss: dismissEditing,
            navigateInCurrentTab: tabManager.activeTab != nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            suppressInitialSearch = false
        }

        mouseHasMoved = false
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                mouseHasMoved = true
                if let monitor = mouseMonitor {
                    NSEvent.removeMonitor(monitor)
                    mouseMonitor = nil
                }
                return event
            }
        }
    }

    private func cleanupInlineLauncher() {
        // Synchronously, in the same pass that ended editing. Left to the overlay's
        // `.onDisappear` it outlived the list by a frame and `BrowserView` kept a hole
        // cut in its backdrop with nothing behind it.
        appState.urlSuggestionsFrame = .zero
        suggestionsHeight = 0
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        DispatchQueue.main.async {
            guard !appState.isURLBarEditing else { return }
            mouseHasMoved = false
            suppressInitialSearch = false
            launcherInput = ""
            launcherViewModel.reset()
        }
    }

    private func dismissEditing() {
        DispatchQueue.main.async {
            guard appState.isURLBarEditing else { return }
            withAnimation(AnimationSettings.easeOut(0.15)) {
                appState.isURLBarEditing = false
            }
        }
    }

    private func onLauncherSubmit(_ newInput: String? = nil) {
        let correctInput = newInput ?? launcherInput

        if let defaultEngine = launcherViewModel.searchEngineService.getDefaultSearchEngine(
            for: tabManager.activeContainer?.id
        ) {
            let customEngine = launcherViewModel.searchEngineService.settings.customSearchEngines
                .first { $0.searchURL == defaultEngine.searchURL }
            let match = defaultEngine.toLauncherMatch(
                originalAlias: correctInput,
                customEngine: customEngine
            )
            if let url = launcherViewModel.searchEngineService.createSearchURL(for: match, query: correctInput) {
                if let activeTab = tabManager.activeTab {
                    activeTab.loadURL(url.absoluteString)
                } else {
                    // No tab to navigate: the field is still usable, so open one.
                    tabManager.openTab(
                        url: url,
                        historyManager: historyManager,
                        downloadManager: downloadManager,
                        isPrivate: privacyMode.isPrivate
                    )
                }
            }
        }
        dismissEditing()
    }
}
