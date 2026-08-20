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
