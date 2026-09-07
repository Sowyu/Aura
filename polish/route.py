import sys, json, collections, re
# Ownership by path rule; first match wins.
RULES = [
 ('core',      [r'aura/App/', r'Core/Constants/KeyboardShortcuts', r'Core/Services/App/CustomKeyboardShortcutManager', r'Core/Constants/AppEvents', r'Shared/Components/Menu/', r'Features/Browser/Views/BrowserView\.swift', r'Features/Browser/Views/FloatingTabSwitcher', r'Tabs/Views/FloatingTabSwitcher', r'Core/Services/App/KeyModifierListener', r'Core/Platform/AuraWindow', r'Core/Utilities/WindowFactory', r'Core/Extensions/NSWindow', r'Core/Platform/Representables/', r'Features/Browser/Components/WindowControls', r'Features/Passwords/Views/PasswordsWindow', r'Browser/Views/BrowserSplitView', r'Browser/Views/BrowserContentContainer', r'Browser/Views/BrowserWebContentView', r'Browser/Views/FloatingSidebarOverlay']),
 ('launcher',  [r'Features/Launcher/', r'Browser/Views/HomePageView', r'Features/Search/']),
 ('urlbar',    [r'Features/Browser/URLBar/', r'Features/Browser/Toolbar/', r'Features/Browser/Components/', r'Features/Browser/SiteInfo/', r'Core/Utilities/URLDisplayUtils', r'Core/Utilities/ClipboardUtils', r'Sidebar/Views/SidebarURLDisplay', r'Browser/Views/PageContextMenu']),
 ('sidebar',   [r'Features/Sidebar/', r'Features/Tabs/Views/', r'Features/Tabs/DragAndDrop/', r'Shared/Layout/', r'Features/Containers/']),
 ('tabs-engine',[r'Features/Tabs/', r'Core/BrowserEngine/', r'Core/Domain/', r'Features/Downloads/Services/', r'Features/Privacy/', r'Features/FindInPage/', r'Features/PageTools/', r'Features/Player/', r'Features/Browser/Permissions/', r'Features/History/Models/', r'Features/Bookmarks/Services/', r'Core/Services/Web/', r'Core/Services/App/', r'Core/Utilities/', r'Core/Extensions/']),
 ('settings',  [r'Features/Settings/', r'Core/Styles/AuraGlass']),
 ('panels',    [r'Features/History/', r'Features/Bookmarks/', r'Features/Downloads/', r'Features/Files/', r'Features/Extensions/Views/', r'Features/Passwords/', r'Features/Importer/', r'Browser/Views/StatusPageView', r'Browser/Views/SessionRestoreBar', r'Features/Onboarding/', r'Browser/Views/PasswordAutofillOverlay']),
 ('design',    [r'Core/Constants/', r'Core/Styles/', r'Shared/']),
 ('extensions',[r'Features/Extensions/', r'Resources/WebScripts/', r'auraWebBundle/', r'scripts/']),
 ('docs',      [r'\.md$', r'project\.yml', r'\.github/']),
]
def owner(path):
    for name, pats in RULES:
        for p in pats:
            if re.search(p, path): return name
    return 'misc'
EXCLUDE = {'slop-sweep-11', 'slop-sweep-8'}   # renames: a solo pass after the merges
DEFER_OWNERS = {'docs'}                          # docs are rewritten last, against the merged code
OWNERSHIP = {
 'core': ['aura/App/** (OraApp, OraRoot, OraCommands)', 'aura/Core/Constants/KeyboardShortcuts.swift', 'aura/Core/Constants/AppEvents.swift', 'aura/Core/Services/App/CustomKeyboardShortcutManager.swift', 'aura/Core/Services/App/KeyModifierListener.swift', 'aura/Core/Platform/** (AuraWindow, Representables)', 'aura/Core/Utilities/WindowFactory.swift', 'aura/Core/Extensions/NSWindow+Extensions.swift', 'aura/Shared/Components/Menu/**', 'aura/Features/Browser/Views/BrowserView.swift, BrowserSplitView.swift, BrowserContentContainer.swift, BrowserWebContentView.swift, FloatingSidebarOverlay.swift', 'aura/Features/Browser/Components/WindowControls.swift', 'aura/Features/Tabs/Views/FloatingTabSwitcher* (if present)', 'aura/Features/Passwords/Views/PasswordsWindow.swift', 'auraTests files for the above'],
 'launcher': ['aura/Features/Launcher/**', 'aura/Features/Browser/Views/HomePageView.swift', 'aura/Features/Search/**', 'auraTests/Launcher*.swift, HomeTabTests.swift'],
 'urlbar': ['aura/Features/Browser/URLBar/**', 'aura/Features/Browser/Toolbar/**', 'aura/Features/Browser/Components/** (except WindowControls.swift)', 'aura/Features/Browser/SiteInfo/**', 'aura/Features/Browser/Views/PageContextMenu.swift', 'aura/Core/Utilities/URLDisplayUtils.swift, ClipboardUtils.swift', 'aura/Features/Sidebar/Views/SidebarURLDisplay.swift', 'auraTests/ToolbarIconTests.swift, ChromeRevealZoneTests.swift, SiteInfoTests.swift'],
 'sidebar': ['aura/Features/Sidebar/**', 'aura/Features/Tabs/Views/**', 'aura/Features/Tabs/DragAndDrop/**', 'aura/Shared/Layout/**', 'aura/Features/Containers/**', 'auraTests/TabDrag*, TabDrop*, SpaceHeaderTests, SpaceIconTests, TabFolderTests, BrowsingContainerTests'],
 'tabs-engine': ['aura/Features/Tabs/State/**, Models/**, Browser/**', 'aura/Core/BrowserEngine/**', 'aura/Core/Domain/**', 'aura/Features/Downloads/Services/**', 'aura/Features/Privacy/**', 'aura/Features/FindInPage/**', 'aura/Features/PageTools/**', 'aura/Features/Player/**', 'aura/Features/Browser/Permissions/**', 'aura/Features/History/Models/**', 'aura/Features/Bookmarks/Services/**', 'aura/Core/Services/** (except App/CustomKeyboardShortcutManager and KeyModifierListener)', 'aura/Core/Utilities/** (except WindowFactory, URLDisplayUtils, ClipboardUtils)', 'aura/Core/Extensions/** (except NSWindow+Extensions)', 'auraTests for the above (TabLifecycle, TabHibernation*, SessionRestore, BrowserPage*, Downloads*, FaviconDecoder, SiteZoom, JavaScriptPolicy, SitePermission, WebBundle*)'],
 'settings': ['aura/Features/Settings/**', 'aura/Core/Styles/AuraGlass.swift', 'auraTests/SettingsSectionsTests.swift, GlassChromeTests.swift, KeyboardPolishTests.swift'],
 'panels': ['aura/Features/History/Views/**', 'aura/Features/Bookmarks/Views/**', 'aura/Features/Downloads/Views/**', 'aura/Features/Files/**', 'aura/Features/Extensions/Views/**', 'aura/Features/Passwords/** (except PasswordsWindow.swift)', 'aura/Features/Importer/**', 'aura/Features/Onboarding/**', 'aura/Features/Browser/Views/StatusPageView.swift, SessionRestoreBar.swift, PasswordAutofillOverlayView.swift', 'auraTests/HistoryPanelTests, BookmarkStoreTests, DataPortabilityTests, LocalFileTests, OnboardingTests, FirefoxAddonTests'],
 'design': ['aura/Core/Constants/** (except KeyboardShortcuts.swift, AppEvents.swift)', 'aura/Core/Styles/** (except AuraGlass.swift)', 'aura/Shared/** (except Menu/** and Layout/**)', 'auraTests/AuraColorPickerTests, AuraMenu*Tests'],
 'extensions': ['aura/Features/Extensions/Services/**, Models/**', 'aura/Resources/WebScripts/**', 'auraWebBundle/**', 'scripts/*.cjs', 'auraTests/Extension*, WebRequestBrokerTests, FullUBlockOriginTests'],
 'docs': ['*.md at the repo root', 'project.yml', '.github/**'],
}
src = sys.argv[1]
data = json.load(open(src))
packages = collections.defaultdict(list)
for area, r in data.items():
    items = r['kept'] if 'kept' in r else r['findings']
    for f in items:
        if f['id'] in EXCLUDE: continue
        o = owner(f['file'])
        others = sorted({owner(p) for p in f['files_to_touch']} - {o})
        f2 = dict(f); f2['area'] = area; f2['owner'] = o; f2['cross_owners'] = others
        packages[o].append(f2)
order = [o for o in ['tabs-engine','core','panels','sidebar','urlbar','design','launcher','settings','extensions'] if o in packages]
json.dump({'packages': {o: packages[o] for o in order}, 'order': order, 'ownership': OWNERSHIP, 'deferred': {o: packages[o] for o in DEFER_OWNERS if o in packages}, 'effort': {'core':'high','tabs-engine':'high','launcher':'high','design':'medium','panels':'medium','sidebar':'medium','urlbar':'medium','settings':'medium','extensions':'medium'}}, open('polish/packages.json','w'), indent=1)
for o, items in sorted(packages.items(), key=lambda x: -len(x[1])):
    cross = sum(1 for f in items if f['cross_owners'])
    sev = collections.Counter(f['severity'] for f in items)
    print(f"{o:12} {len(items):3} findings  cross-owner {cross:2}  high {sev['high']} med {sev['medium']} low {sev['low']}")
misc = packages.get('misc', [])
for f in misc: print('  MISC', f['id'], f['file'])
