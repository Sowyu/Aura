import AppKit
import SwiftUI

enum SettingsTab: String, Hashable, CaseIterable {
    case lookAndFeel
    case tabManagement
    case shortcuts
    case search
    case privacy
    case passwords
    case downloads
    case browsing
    case spaces
    case accessibility
    case languages
    case permissions
    case about
    case extensions

    /// Raw values written by older builds. Without this a saved selection would fall
    /// back to the first section and silently lose the user's place.
    private static let legacyRawValues: [String: SettingsTab] = [
        "general": .lookAndFeel,
        "searchEngines": .search
    ]

    static func resolve(rawValue: String) -> SettingsTab? {
        SettingsTab(rawValue: rawValue) ?? legacyRawValues[rawValue]
    }

    var title: String {
        switch self {
        case .lookAndFeel: return "Look and Feel"
        case .tabManagement: return "Tab Management"
        case .shortcuts: return "Keyboard Shortcuts"
        case .search: return "Search"
        case .privacy: return "Privacy and Security"
        case .passwords: return "Passwords and Autofill"
        case .downloads: return "Downloads"
        case .browsing: return "Tabs and Browsing"
        case .spaces: return "Spaces"
        case .accessibility: return "Accessibility"
        case .languages: return "Languages"
        case .permissions: return "Permissions and Data"
        case .about: return "About Aura"
        case .extensions: return "Extensions"
        }
    }

    var symbol: String {
        switch self {
        case .lookAndFeel: return "paintpalette"
        case .tabManagement: return "rectangle.stack"
        case .shortcuts: return "keyboard"
        case .search: return "magnifyingglass"
        case .privacy: return "lock.shield"
        case .passwords: return "key"
        case .downloads: return "arrow.down.circle"
        case .browsing: return "cursorarrow.rays"
        case .spaces: return "rectangle.3.group"
        case .accessibility: return "accessibility"
        case .languages: return "globe"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        case .extensions: return "puzzlepiece.extension"
        }
    }

    var subtitle: String {
        switch self {
        case .lookAndFeel:
            return "Appearance, accent colour, glass chrome, and window layout."
        case .tabManagement:
            return "How long tabs stay live, how many, and where new ones land."
        case .shortcuts:
            return "Keyboard shortcuts and command mappings."
        case .search:
            return "Default search providers, AI engines, and custom shortcuts."
        case .privacy:
            return "Blocking, JavaScript, cookies, and clearing browsing data."
        case .passwords:
            return "Password manager integration, vault access, and autofill behavior."
        case .downloads:
            return "Where files are saved and what happens once they arrive."
        case .browsing:
            return "The launcher, the home page, and what happens on launch and quit."
        case .spaces:
            return "Space-specific defaults and per-space data controls."
        case .accessibility:
            return "Motion, minimum text size, and scroll bars."
        case .languages:
            return "Spell checking and the languages sent to websites."
        case .permissions:
            return "Per-site rules and the data each space has stored."
        case .about:
            return "Version, updates, licence, and credits."
        case .extensions:
            return "Web extensions installed from unpacked folders."
        }
    }
}

struct SettingsContentView: View {
    static let selectedTabDefaultsKey = "settings.selectedTab"

    /// The two rules in the sidebar list: browser behaviour, then the system-level
    /// sections, then extensions on their own.
    private static let dividedGroups: [[SettingsTab]] = [
        [.lookAndFeel, .tabManagement, .shortcuts, .search, .privacy,
         .passwords, .downloads, .browsing, .spaces],
        [.accessibility, .languages, .permissions, .about],
        [.extensions]
    ]

    /// Section to preselect, e.g. from a `aura://settings/<section>` tab URL.
    let initialTab: SettingsTab?

    @AppStorage(Self.selectedTabDefaultsKey) private var selectionRawValue: String = SettingsTab
        .lookAndFeel.rawValue

    private var selection: Binding<SettingsTab> {
        Binding(
            get: { selectedTab },
            set: { selectionRawValue = $0.rawValue }
        )
    }

    private var selectedTab: SettingsTab {
        SettingsTab.resolve(rawValue: selectionRawValue) ?? .lookAndFeel
    }

    var body: some View {
        layout
            .onChange(of: initialTab, initial: true) { _, newValue in
                guard let newValue else { return }
                selectionRawValue = newValue.rawValue
            }
    }

    /// No `NavigationSplitView`: it reports a large minimum width and adds its own titlebar
    /// inset plus a floating sidebar toggle, which overflowed the browser's split pane.
    private var layout: some View {
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
        List(selection: selection) {
            ForEach(Array(Self.dividedGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .tag(tab)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            }
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
        case .lookAndFeel:
            LookAndFeelSettingsView()
        case .tabManagement:
            TabManagementSettingsView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .search:
            SearchEngineSettingsView()
        case .privacy:
            PrivacySettingsView()
        case .passwords:
            PasswordsSettingsView()
        case .downloads:
            DownloadsSettingsView()
        case .browsing:
            BrowsingSettingsView()
        case .spaces:
            SpacesSettingsView()
        case .accessibility:
            AccessibilitySettingsView()
        case .languages:
            LanguagesSettingsView()
        case .permissions:
            PermissionsSettingsView()
        case .about:
            AboutSettingsView()
        case .extensions:
            ExtensionsSettingsView()
        }
    }
}
