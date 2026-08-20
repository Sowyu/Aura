import AppKit
import SwiftUI

enum SettingsTab: String, Hashable, CaseIterable {
    case general
    case spaces
    case passwords
    case shortcuts
    case searchEngines
    case extensions

    var title: String {
        switch self {
        case .general: return "General"
        case .spaces: return "Spaces"
        case .passwords: return "Passwords"
        case .shortcuts: return "Shortcuts"
        case .searchEngines: return "Search"
        case .extensions: return "Extensions"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .spaces: return "rectangle.3.group"
        case .passwords: return "key.horizontal"
        case .shortcuts: return "command"
        case .searchEngines: return "magnifyingglass"
        case .extensions: return "puzzlepiece.extension"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "Browser defaults, app behavior, and software updates."
        case .spaces:
            return "Space-specific defaults and per-space data controls."
        case .passwords:
            return "Password manager integration, vault access, and autofill behavior."
        case .shortcuts:
            return "Keyboard shortcuts and command mappings."
        case .searchEngines:
            return "Default search providers, AI engines, and custom shortcuts."
        case .extensions:
            return "Web extensions installed from unpacked folders."
        }
    }
}

struct SettingsWindowRoot: View {
    var body: some View {
        SettingsContentView(initialTab: nil)
            .environment(ToastManager.shared)
    }
}

struct SettingsContentView: View {
    static let selectedTabDefaultsKey = "settings.selectedTab"

    /// Section to preselect, e.g. from a `aura://settings/<section>` tab URL.
    let initialTab: SettingsTab?
    /// Rendered inside a browser tab (`aura://settings`) instead of the standalone settings window.
    /// A tab has no window toolbar, and `NavigationSplitView` would impose its own minimum width
    /// and floating sidebar toggle on the surrounding browser layout.
    var embedded: Bool = false

    @AppStorage(Self.selectedTabDefaultsKey) private var selectionRawValue: String = SettingsTab.general.rawValue

    private var selection: Binding<SettingsTab> {
        Binding(
            get: { SettingsTab(rawValue: selectionRawValue) ?? .general },
            set: { selectionRawValue = $0.rawValue }
        )
    }

    private var selectedTab: SettingsTab {
        SettingsTab(rawValue: selectionRawValue) ?? .general
    }

    var body: some View {
        Group {
            if embedded {
                embeddedLayout
            } else {
                windowLayout
            }
        }
        .onChange(of: initialTab, initial: true) { _, newValue in
            guard let newValue else { return }
            selectionRawValue = newValue.rawValue
        }
    }

    private var windowLayout: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(SettingsMetrics.sidebarWidth)
                .padding(.top, 8)
        } detail: {
            detailPane
                .navigationTitle(selectedTab.title)
                .navigationSubtitle(selectedTab.subtitle)
        }
    }

    /// No `NavigationSplitView`: it reports a large minimum width and adds its own titlebar
    /// inset plus a floating sidebar toggle, which overflowed the browser's split pane.
    private var embeddedLayout: some View {
        HStack(spacing: 0) {
            sidebarList
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(width: SettingsMetrics.sidebarWidth)
                .padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                detailPane
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarList: some View {
        List(SettingsTab.allCases, id: \.self, selection: selection) { tab in
            Label(tab.title, systemImage: tab.symbol)
                .tag(tab)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
    }

    /// Stands in for the window mode navigation title, which a tab cannot show.
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedTab.title)
                .font(.title3.weight(.semibold))
            Text(selectedTab.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Matches `SettingsSection`, so the header lines up with the cards below.
        // The section supplies its own top padding, hence none at the bottom here.
        .padding(.horizontal, SettingsMetrics.pagePadding)
        .padding(.top, SettingsMetrics.pagePadding)
    }

    // Section views bring their own `ScrollView` (see `SettingsSection`), so none is added here.
    private var detailPane: some View {
        detailView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView()
        case .spaces:
            SpacesSettingsView()
        case .passwords:
            PasswordsSettingsView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .searchEngines:
            SearchEngineSettingsView()
        case .extensions:
            ExtensionsSettingsView()
        }
    }
}
