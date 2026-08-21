# Third-Party Notices

This repository includes third-party source code and other third-party components that remain subject to their own licenses.

## SplitView

- Upstream project: [stevengharris/SplitView](https://github.com/stevengharris/SplitView)
- Upstream source path: `Sources/SplitView`
- Local path: `ora/Shared/Layout/SplitView`
- License: MIT
- Included license text: `Vendor/SplitView/LICENSE`

The files in `ora/Shared/Layout/SplitView` were copied from the upstream `SplitView` project and may include local modifications.

## AdGuard Scriptlets

- Upstream project: [AdguardTeam/Scriptlets](https://github.com/AdguardTeam/Scriptlets)
- Upstream source path: `dist/scriptlets/index.js` from `@adguard/scriptlets@2.3.1` on npm
- Local path: `aura/Resources/WebScripts/vendor/adguard-scriptlets.js`
- License: GPL-3.0
- Included license text: `aura/Resources/WebScripts/vendor/LICENSE-adguard-scriptlets.txt`

The bundle is verbatim except for its final line, where the ES module export was replaced
by a global assignment so the file can be evaluated in a JavaScriptCore context.

## AdGuard ExtendedCss

- Upstream project: [AdguardTeam/ExtendedCss](https://github.com/AdguardTeam/ExtendedCss)
- Upstream source path: `dist/extended-css.min.js` from `@adguard/extended-css@2.1.1` on npm
- Local path: `aura/Resources/WebScripts/vendor/adguard-extended-css.js`
- License: GPL-3.0
- Included license text: `aura/Resources/WebScripts/vendor/LICENSE-adguard-extended-css.txt`

Copied verbatim.

## uBlock Origin

- Upstream project: [gorhill/uBlock](https://github.com/gorhill/uBlock)
- Upstream source: `ublock_origin-1.73.0.xpi`, the Firefox build published on
  [addons.mozilla.org](https://addons.mozilla.org/firefox/addon/ublock-origin/)
- Local path: `aura/Resources/Extensions/ublock-origin.xpi`
- Version: 1.73.0 (SHA-256 `bccc51a773150af4af6e1fd62c7bfdeb7238b79ff2381b998fa9f2e38f64786a`)
- License: GPL-3.0
- Included license text: `aura/Resources/Extensions/LICENSE-ublock-origin.txt`

The archive is the signed AMO build, unmodified. Aura unpacks it into the profile
on first launch and installs it like any other extension. The installed copy is
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
