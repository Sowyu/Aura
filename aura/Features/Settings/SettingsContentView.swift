import SwiftUI

enum SettingsTab: String, Hashable, CaseIterable {
    case lookAndFeel
    case window
    case browsing
    case bookmarks
    case search
    case privacy
    case passwords
    case downloads
    case spaces
    case containers
    case accessibility
    case languages
    case shortcuts
    case permissions
    case about
    case extensions

    /// Raw values written by older builds. Without this a saved selection would fall
    /// back to the first section and silently lose the user's place. "tabManagement"
    /// is here because that page is now a group inside "Tabs and Browsing".
    private static let legacyRawValues: [String: SettingsTab] = [
        "general": .lookAndFeel,
        "searchEngines": .search,
        "tabManagement": .browsing
    ]

    static func resolve(rawValue: String) -> SettingsTab? {
        SettingsTab(rawValue: rawValue) ?? legacyRawValues[rawValue]
    }

    var title: String {
        switch self {
        case .lookAndFeel: return "Look and Feel"
        case .window: return "Window"
        case .shortcuts: return "Keyboard Shortcuts"
        case .search: return "Search"
        case .privacy: return "Privacy and Security"
        case .passwords: return "Passwords and Autofill"
        case .downloads: return "Downloads"
        case .browsing: return "Tabs and Browsing"
        case .bookmarks: return "Bookmarks"
        case .spaces: return "Spaces"
        case .containers: return "Containers"
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
        case .window: return "macwindow"
        case .shortcuts: return "keyboard"
        case .search: return "magnifyingglass"
        case .privacy: return "lock.shield"
        case .passwords: return "key"
        case .downloads: return "arrow.down.circle"
        case .browsing: return "rectangle.stack"
        case .bookmarks: return "bookmark"
        case .spaces: return "rectangle.3.group"
        case .containers: return "square.stack.3d.up"
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
            return "Appearance, accent colour, and the glass chrome."
        case .window:
            return "Where the chrome sits, what it shows, and when it hides."
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
            return "How long tabs stay live, where new ones land, the launcher, and the home page."
        case .bookmarks:
            return "Saved pages, folders, and the reading list."
        case .spaces:
            return "Space-specific defaults and per-space data controls."
        case .containers:
            return "Separate cookie jars a tab can open in."
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

    /// Every card header and control label the section shows, flattened. The search field
    /// matches against these, so typing "compact" finds Window even though no nav row says
    /// so. Selecting the section is the whole answer; nothing scrolls to the card.
    /// Keep in step with the section views by hand: one static list beats reflection over
    /// a view tree that only exists while it is on screen.
    var searchKeywords: [String] {
        switch self {
        case .lookAndFeel:
            return ["appearance", "light", "dark", "system theme", "accent colour", "accent color",
                    "liquid glass", "glass tint", "colour"]
        case .window:
            return ["window layout", "sidebar position", "left", "right", "toolbar", "show the toolbar",
                    "full url", "address bar", "blur", "launcher blur", "compact mode", "chrome"]
        case .browsing:
            return ["tabs", "keeping tabs live", "hibernation", "unload idle tabs", "memory pressure",
                    "new tabs and folders", "media", "picture in picture", "launcher", "home page",
                    "links from other apps", "launch and quit", "reopen tabs", "ask before quitting",
                    "default browser"]
        case .bookmarks:
            return ["bookmarks", "bookmark", "bookmarks bar", "reading list", "unread",
                    "saved pages", "folders"]
        case .search:
            return ["search engine", "add new search engine", "default engines", "ai chat engine",
                    "search shortcuts", "keyword"]
        case .privacy:
            return ["content blocking", "fingerprinting", "third-party trackers", "javascript",
                    "cookies", "clear browsing data", "history", "cache"]
        case .passwords:
            return ["password manager", "autofill", "saved credentials", "vault",
                    "auto-submit", "prompt to save passwords"]
        case .downloads:
            return ["save files to", "download folder", "ask where to save", "after downloading",
                    "open safe files"]
        case .spaces:
            return ["space defaults", "search engine per space", "auto clear tabs",
                    "sites pinned to a space", "clear data", "containers"]
        case .containers:
            return ["containers", "container", "cookie jar", "separate cookies", "separate logins",
                    "new container", "container colour", "container color", "container icon",
                    "multi-account"]
        case .accessibility:
            return ["motion", "reduce motion", "minimum font size", "text size", "scroll bars"]
        case .languages:
            return ["spell checking", "languages sent to websites", "dictionary"]
        case .shortcuts:
            return ["keyboard shortcuts", "key bindings", "commands"]
        case .permissions:
            return ["javascript rules", "sites pinned to a space", "site data", "cookies and storage"]
        case .about:
            return ["version", "updates", "check for updates", "licence", "license", "credits",
                    "third-party notices"]
        case .extensions:
            return ["extensions", "web extensions", "unpacked"]
        }
    }

    /// Case-insensitive match over the nav row's own title and everything the section holds.
    func matches(query: String) -> Bool {
        let needle = query.lowercased()
        if title.lowercased().contains(needle) { return true }
        return searchKeywords.contains { $0.contains(needle) }
    }
}

struct SettingsContentView: View {
    static let selectedTabDefaultsKey = "settings.selectedTab"

    @Environment(\.theme) private var theme

    /// The two rules in the sidebar list: the sections that change how Aura browses, then
    /// the system-level ones. Extensions is not in here; it is a link out to
    /// `aura://extensions`.
    private static let dividedGroups: [[SettingsTab]] = [
        [.lookAndFeel, .window, .browsing, .bookmarks, .search, .privacy,
         .passwords, .downloads, .spaces, .containers],
        [.accessibility, .languages, .shortcuts, .permissions, .about]
    ]

    /// Section to preselect, e.g. from a `aura://settings/<section>` tab URL.
    let initialTab: SettingsTab?

    @AppStorage(Self.selectedTabDefaultsKey) private var selectionRawValue: String = SettingsTab
        .lookAndFeel.rawValue
    @State private var query = ""

    private var selection: Binding<SettingsTab> {
        Binding(
            get: { selectedTab },
            set: { selectionRawValue = $0.rawValue }
        )
    }

    private var selectedTab: SettingsTab {
        SettingsTab.resolve(rawValue: selectionRawValue) ?? .lookAndFeel
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Filtering collapses the two rules into one flat list: with most rows gone, a
    /// divider between the survivors separates nothing.
    private var visibleGroups: [[SettingsTab]] {
        guard !trimmedQuery.isEmpty else { return Self.dividedGroups }
        let hits = Self.dividedGroups.flatMap { $0 }.filter { $0.matches(query: trimmedQuery) }
        return hits.isEmpty ? [] : [hits]
    }

    private var showsExtensionsRow: Bool {
        trimmedQuery.isEmpty || SettingsTab.extensions.matches(query: trimmedQuery)
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
            navColumn

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                detailPane
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // The same fill the home page gives the content pane, so a settings tab reads as
        // the same surface as every other tab instead of a black hole next to the cards.
        .background(theme.popoverBackground)
    }

    private var navColumn: some View {
        VStack(spacing: 8) {
            searchField
                .padding(.horizontal, SettingsMetrics.gutter)

            sidebarList
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
        }
        .frame(width: SettingsMetrics.sidebarWidth)
        .padding(.vertical, 8)
    }

    /// Same fill, radius and hairline as `LauncherField`, at the height a sidebar row wants.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)

            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !trimmedQuery.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SettingsMetrics.searchFieldHeight)
        .background(theme.launcherMainBackground, in: .rect(cornerRadius: AuraRadius.row))
        .overlay(
            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                .stroke(theme.foreground.opacity(LauncherField.hairline), lineWidth: 1)
        )
    }

    private var sidebarList: some View {
        List(selection: selection) {
            ForEach(Array(visibleGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .tag(tab)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            }

            if showsExtensionsRow {
                if !visibleGroups.isEmpty { Divider() }
                extensionsLinkRow
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }

            if visibleGroups.isEmpty && !showsExtensionsRow {
                Text("No settings match that")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 2, trailing: 8))
            }
        }
    }

    /// Extensions live on `aura://extensions`, not in Settings, so this row leaves the
    /// window instead of selecting a section. The arrow is what says so.
    private var extensionsLinkRow: some View {
        Button(action: ExtensionsSettingsView.openStore) {
            HStack(spacing: 6) {
                Label(SettingsTab.extensions.title, systemImage: SettingsTab.extensions.symbol)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.mutedForeground)
            }
            .contentShape(.rect(cornerRadius: AuraRadius.button))
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
    }

    /// Stands in for the window mode navigation title, which a tab cannot show.
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedTab.title)
                .font(.system(size: 15, weight: .semibold))
            Text(selectedTab.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Matches `SettingsSection`, so the header lines up with the cards below.
        // The section supplies its own top padding, hence none at the bottom here.
        .padding(.horizontal, SettingsMetrics.gutter)
        .padding(.top, SettingsMetrics.gutter)
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
        case .window:
            WindowSettingsView()
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
        case .bookmarks:
            BookmarksSettingsView()
        case .spaces:
            SpacesSettingsView()
        case .containers:
            ContainersSettingsView()
        case .accessibility:
            AccessibilitySettingsView()
        case .languages:
            LanguagesSettingsView()
        case .permissions:
            PermissionsSettingsView()
        case .about:
            AboutSettingsView()
        // Only reachable from a selection an older build saved; the row above leaves
        // for `aura://extensions` instead.
        case .extensions:
            ExtensionsSettingsView()
        }
    }
}
