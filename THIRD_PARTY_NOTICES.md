# Third-party notices

Aura includes third-party components that remain subject to their own licenses.
The referenced license texts ship in this repository at the paths given below.
Files derived from other projects also name their upstream source in a header
comment at the top of the file.

## SplitView

- Upstream: [stevengharris/SplitView](https://github.com/stevengharris/SplitView), `Sources/SplitView`
- Files: `aura/Shared/Layout/SplitView/`
- License: MIT (`Vendor/SplitView/LICENSE`)

Copied from upstream, with local modifications.

## uBlock Origin Lite

- Upstream: [uBlockOrigin/uBOL-home](https://github.com/uBlockOrigin/uBOL-home), built from
  [gorhill/uBlock](https://github.com/gorhill/uBlock); Firefox release build, add-on id
  `uBOLiteRedux@raymondhill.net`
- File: `aura/Resources/Extensions/ublock-origin-lite.xpi`
- Version: 2026.820.1159
- SHA-256: `b23d4d487e885235fb01277ef0fad00531bdd5d20d407f5d74ce48e90aba817e`
- License: GPL-3.0 (`aura/Resources/Extensions/LICENSE-ublock-origin-lite.txt`)

The archive is the unmodified signed release build. At installation Aura adds its
compatibility script (`aura-shim.js`) and rewrites `manifest.json` to load it; the
original manifest is preserved alongside as `manifest.original.json`.

## uBlock Origin

- Upstream: [gorhill/uBlock](https://github.com/gorhill/uBlock); signed Firefox release
  build `uBlock0_1.73.0.firefox.signed.xpi`, add-on id `uBlock0@raymondhill.net`
- Corresponding source: https://github.com/gorhill/uBlock/releases/tag/1.73.0
- File: `aura/Resources/Extensions/ublock-origin.xpi`
- Version: 1.73.0
- SHA-256: `bccc51a773150af4af6e1fd62c7bfdeb7238b79ff2381b998fa9f2e38f64786a`
- License: GPL-3.0 (`aura/Resources/Extensions/LICENSE-ublock-origin.txt`)

The archive is the unmodified signed release build; the version and hash above are
verified before it is unpacked. At installation Aura applies the same manifest patch
described for uBlock Origin Lite.

## Space icons (Ionicons, via Zen Browser)

- Upstream: [zen-browser/desktop](https://github.com/zen-browser/desktop),
  `src/browser/themes/shared/zen-icons/common/selectable/*.svg`; the glyphs originate
  from [Ionicons](https://github.com/ionic-team/ionicons) by Ionic
- Files: `aura/Resources/Icons/Spaces/`
- Licenses: MIT (`aura/Resources/Icons/Spaces/LICENSE-ionicons.txt`) and MPL-2.0
  (`aura/Resources/Icons/Spaces/LICENSE-zen-browser.txt`); the MPL headers are retained

Modifications: the Firefox-only `#filter` preprocessor line was removed, and the
Firefox-only `fill="context-fill"` and `fill-opacity="context-fill-opacity"`
attributes were replaced with `fill="#000000"`. Path data is unchanged.

## Firefox toolbar icons

- Upstream: [mozilla-firefox/firefox](https://github.com/mozilla-firefox/firefox),
  `browser/themes/shared/icons/back.svg`, `forward.svg`, `history.svg`, `home.svg`,
  and `toolkit/themes/shared/icons/reload.svg`
- Files: `aura/Resources/Icons/Toolbar/`
- License: MPL-2.0; the header is retained in each file

Modifications: the Firefox-only `fill="context-fill"` and
`fill-opacity="context-fill-opacity"` attributes were replaced with
`fill="#000000"`; of the two glyph variants each upstream file carries, only the
`nova` paths were kept and the Firefox-only `<style>` switching block was removed;
the files were renamed with a `toolbar-` prefix. Path data is unchanged.

## Nook Browser

- Upstream: [nook-browser/nook](https://github.com/nook-browser/nook)
- Author: Maciek Bagiński and the Nook contributors
- License: GPL-3.0 (the license Aura ships under)

Portions of Aura are derived from Nook, adapted to Aura's architecture:

| Aura | Upstream |
| --- | --- |
| History panel (`aura/Features/History/`) | `Nook/Components/Sidebar/Menu/SidebarMenuHistoryTab.swift` |
| Tab hibernation policy (`aura/Features/Tabs/State/TabManager+Hibernation.swift`) | `Nook/Components/Browser/Window/TabCompositorView.swift`, `Settings/NookSettingsService.swift` |
| Sidebar tab drag and drop (`aura/Features/Tabs/DragAndDrop/`) | `Nook/Components/DragDrop/`, `Nook/Components/Sidebar/SpaceSection/SpaceView.swift` |
| Popup adoption, crash backoff, attachment download check (`aura/Core/BrowserEngine/BrowserPage.swift`) | `Nook/Models/Tab/Tab.swift` |
| Extension popup wake and options page (`aura/Features/Extensions/Services/`) | `Nook/Managers/ExtensionManager/ExtensionManager+Delegate.swift` |
| Extension popup clipboard | `Nook/Managers/ExtensionManager/PopupUIDelegate.swift` |
| Window frame autosave (`aura/Core/Utilities/WindowFactory.swift`) | `App/NookApp.swift` |

## Beam (autocomplete scoring)

- Upstream: [beamlegacy/beam](https://github.com/beamlegacy/beam),
  `AutocompleteResult.swift`, `AutocompleteManager+Sorting.swift`,
  `String+CommonPrefix.swift`
- File: `aura/Features/Launcher/State/LauncherResultScoring.swift`
- License: MIT, Copyright (c) 2022 Beam SAS; the notice is retained in the file header

The prefix-match scoring, score-based merge and result deduplication were ported and
adapted to Aura's launcher types.

## Refrax (first-responder lock)

- Upstream: [refrax-browser/Refrax](https://github.com/refrax-browser/Refrax),
  `Refrax/Core/ViewControllers/RefraxWindow.swift`
- File: `aura/Core/Platform/AuraWindow.swift`
- License: GPL-3.0

The `makeFirstResponder` override is derived from Refrax; Aura restricts it to the
period the app is inactive.
