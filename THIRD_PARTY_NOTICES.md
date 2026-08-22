# Third-Party Notices

This repository includes third-party source code and other third-party components that remain subject to their own licenses.

## SplitView

- Upstream project: [stevengharris/SplitView](https://github.com/stevengharris/SplitView)
- Upstream source path: `Sources/SplitView`
- Local path: `aura/Shared/Layout/SplitView`
- License: MIT
- Included license text: `Vendor/SplitView/LICENSE`

The files in `aura/Shared/Layout/SplitView` were copied from the upstream `SplitView` project and may include local modifications.

## uBlock Origin

- Upstream project: [gorhill/uBlock](https://github.com/gorhill/uBlock)
- Upstream source: `ublock_origin-1.73.0.xpi`, the Firefox build published on
  [addons.mozilla.org](https://addons.mozilla.org/firefox/addon/ublock-origin/)
- Local path: `aura/Resources/Extensions/ublock-origin.xpi`
- Version: 1.73.0 (SHA-256 `bccc51a773150af4af6e1fd62c7bfdeb7238b79ff2381b998fa9f2e38f64786a`)
- License: GPL-3.0
- Included license text: `aura/Resources/Extensions/LICENSE-ublock-origin.txt`

The archive is the signed AMO build, unmodified. Aura unpacks it into the profile
on first launch, enabled, and installs it like any other extension: it is the
only ad and tracker blocker Aura ships. The installed copy is
then patched the same way every extension is: `aura-shim.js` is copied in and
made the first script the background page runs, and `manifest.json` is rewritten
to load it (the untouched original stays as `manifest.original.json`).

## Zen Browser space icons (Ionicons)

- Upstream project: [zen-browser/desktop](https://github.com/zen-browser/desktop)
- Upstream source path: `src/browser/themes/shared/zen-icons/common/selectable/*.svg`
- Local path: `aura/Resources/Icons/Spaces/`
- License: MIT (Ionicons), files carry Zen's MPL-2.0 header
- Included license text: `aura/Resources/Icons/Spaces/LICENSE-ionicons.txt`,
  `aura/Resources/Icons/Spaces/LICENSE-zen-browser.txt`

Zen credits [Ionicons](https://github.com/ionic-team/ionicons) by Ionic (MIT) as the origin of
these glyphs. The path data is verbatim. Two changes make the files parse outside Firefox: the
`#filter` preprocessor line was dropped and the MPL header kept as an XML comment, and the
Firefox-only `fill="context-fill"` / `fill-opacity="context-fill-opacity"` attributes were
replaced by `fill="#000000"` so AppKit can draw them as template images.

## Nook Browser (history panel and hibernation policy)

- Upstream project: [nook-browser/nook](https://github.com/nook-browser/nook)
- Author: Maciek Bagiński
- Upstream source paths: `Nook/Components/Sidebar/Menu/SidebarMenuHistoryTab.swift`,
  `Nook/Components/Browser/Window/TabCompositorView.swift`,
  `Settings/NookSettingsService.swift`
- Local paths: `aura/Features/History/Views/`, `aura/Features/History/Models/HistoryGrouping.swift`,
  `aura/Features/History/Services/HistoryManager.swift`,
  `aura/Features/Tabs/State/TabManager+Hibernation.swift`
- License: GPL-3.0, the same licence Aura ships under

Two features are derived from Nook. The sidebar history panel takes its shape from
`SidebarMenuHistoryTab`: offset paging with infinite scroll, date-grouped sections, a
time-range filter and per-row hover actions. It is restyled to Aura's flat chrome and
runs on Aura's own SwiftData queries. The hibernation policy takes its triggers from
`TabCompositorManager`: a `DispatchSource` memory-pressure source with a 30 second
throttle, an unload pass when the app resigns active, a weighted tab importance score
and a 30 second grace period, with the three presets adapted from `TabManagementMode`.
Aura keeps its own web-view teardown, unsaved-input probe and cross-window guard.

## Nook

- Upstream project: [nook-browser/nook](https://github.com/nook-browser/nook)
- Original author: Maciek Bagiński
- License: GPL-3.0, the same licence Aura ships under

Five pieces of Aura's WebKit layer are ports of Nook's, rewritten to fit Aura's
`BrowserPage` / `ExtensionEngine` split rather than copied line for line. Each site
carries a source comment naming the upstream file.

| Aura | Upstream |
| --- | --- |
| `BrowserPage.createWebViewWith` (popup adoption) | `Nook/Models/Tab/Tab.swift` |
| `BrowserPage.webViewWebContentProcessDidTerminate` (crash backoff) | `Nook/Models/Tab/Tab.swift` |
| `BrowserPage` `Content-Disposition: attachment` download check | `Nook/Models/Tab/Tab.swift` |
| `ExtensionEngine` popup wake and `openOptionsPageFor` | `Nook/Managers/ExtensionManager/ExtensionManager+Delegate.swift` |
| `ExtensionPopupClipboard` | `Nook/Managers/ExtensionManager/PopupUIDelegate.swift` |

## Beam (autocomplete scoring)

- Upstream project: [beamlegacy/beam](https://github.com/beamlegacy/beam)
- Upstream source paths: `Beam/Classes/Components/Autocomplete/AutocompleteResult.swift`,
  `Beam/Classes/Components/Autocomplete/AutocompleteManager+Sorting.swift`,
  `BeamCore/Extensions/String+CommonPrefix.swift`
- Local path: `aura/Features/Launcher/State/LauncherResultScoring.swift`
- License: MIT (Copyright (c) 2022 Beam SAS)
- Included license text: the MIT notice is kept in the file header.

The prefix-match scoring, the score-based merge and the URL/open-tab deduplication were
ported and adapted to Aura's `LauncherSuggestion`. Beam's notes, tab groups and mnemonics
have no counterpart in Aura and were dropped, and Beam rewrites a result's displayed text
to start at the match, which Aura does not.

## Nook (window frame autosave)

- Upstream project: [Nook-Browser/Nook](https://github.com/Nook-Browser/Nook)
- Upstream source path: `App/NookApp.swift`
- Local path: `aura/Core/Utilities/WindowFactory.swift`
- License: GPL-3.0

One line: `setFrameAutosaveName`, so a window reopens where it was left rather than
centred. Attributed in a comment at the call site.

## Refrax (first-responder lock)

- Upstream project: [refrax-browser/Refrax](https://github.com/refrax-browser/Refrax)
- Upstream source path: `Refrax/Core/ViewControllers/RefraxWindow.swift`
- Local path: `aura/Core/Platform/AuraWindow.swift`
- License: GPL-3.0

`NSWindow.makeFirstResponder` is overridden so a designated view can hold keyboard focus
across an app switch, which is what stops the address field losing an edit. Aura only
refuses the change while the app is inactive; Refrax refuses it unconditionally. The rest
of `RefraxWindow` (styling, state restoration) was not taken.
