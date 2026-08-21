# Third-Party Notices

This repository includes third-party source code and other third-party components that remain subject to their own licenses.

## SplitView

- Upstream project: [stevengharris/SplitView](https://github.com/stevengharris/SplitView)
- Upstream source path: `Sources/SplitView`
- Local path: `ora/Shared/Layout/SplitView`
- License: MIT
- Included license text: `Vendor/SplitView/LICENSE`

The files in `ora/Shared/Layout/SplitView` were copied from the upstream `SplitView` project and may include local modifications.

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
