# Polish pass handoff, 8 September 2026

Branch `audit/native-validation-20260907`. Goal set by the owner: a fully polished
browser, every real bug fixed, nothing that reads as generated slop, a custom designed
look rather than stock AppKit, native speed. Trigger complaint: "sometimes ⌘T does not
open the launcher, or it opens and typing goes nowhere".

This file rides the feature branch only; `scripts/check-no-prompt-docs.sh` keeps
`HANDOFF*.md` off `main`. Delete it before merging to `main`.

## Where things stand

Two commits landed on top of `c2f4369` (release v1.2.3), nothing pushed:

| Commit | Change | Verified by |
| --- | --- | --- |
| `d52c2c2` | ⌘T never toggles the launcher closed; a repeat ⌘T bumps `AppState.launcherFocusToken`, which re-runs `LauncherTextField.updateNSView` and asks AppKit for first responder again. `.showLauncher` and `.restoreLastTab` use `.windowOrKey` scope so posts with a nil window (sidebar menus inside `NSHostingView`) are claimed. `TabBrowserPageDelegate.handleURLUpdateMessage` ignores an empty WebKit title, which used to blank the sidebar row for the whole visit. | Full suite 670 tests / 102 suites; keyboard-driven checks in the running Debug build |
| `6aa629b` | `AuraWebBundle.PaintProbe.hostWindow` builds a non-activating `NSPanel` subclass that can never be key or main and reports the `floatingWindow` subrole. As bare borderless `NSWindow`s the two probe windows took key status for about three seconds on the first page load after launch: traffic lights went grey, typing went nowhere, and paneru (the owner's scrolling window manager) followed focus and scrolled the browser window off screen. | Four relaunches, no window jump, verdict still `painted`; gated suites WebBundleTests, WebRequestBrokerTests, BrowserPageTests, 27 tests |

Side effect to know: the bundle page's `requestAnimationFrame` counter only ticks in a
key window, so the probe's `frames` reading is now 0 on a healthy stack. The `screen`
reading (window server capture, fixture share 1.00) decides and `combined` never lets a
still counter outvote it. `frameVerdict` and its tests are unchanged.

A nine-agent fix run over the audit findings was started and died on a session limit
after seven minutes. Its worktrees and branches were discarded; nothing from it is in
the tree.

## The ⌘T complaint, all causes found

Fixed:

1. A second ⌘T toggled the panel shut, so the next keys went to the page (`OraRoot`).
2. The paint probe stole key focus on the first page load (`AuraWebBundlePaintProbe`).
3. The sidebar background menu's New Tab posted a nil window and `.window` scope
   dropped it (`SidebarView.swift:125`).

Still open, with the finding ids in `polish/findings-verified.json`:

4. `launcher-3`: ⌘T does nothing while the Passwords or Settings window is key, or
   when every window is minimised. `OraCommands.swift:26` posts to `NSApp.keyWindow`;
   `AppDelegate.browserWindow(in:)` already exists for the fallback.
5. `onboarding-home-1` / `launcher-5`: `HomePageView.focusField` raises `isEditing`
   for 0.1 s, which sets `wantsFocus` and locks the window's first responder
   (`FirstResponderLock`), and nothing unlocks it. After an app switch the caret goes
   back to the home field instead of the launcher.
6. `launcher-8`: the SwiftUI `FocusState` path in `LauncherMain` is still wired next to
   the AppKit `isEditing: true` path and races it. Remove the `FocusState` half.
7. `windows-chrome-2` / `shortcuts-menus-9`: every menu command posts to
   `NSApp.keyWindow` with no fallback to the owning browser window.

## The audit

15 read-only auditors, one per area, then one skeptic per area who re-read the code and
refuted or kept each finding and added what the auditor missed. Result: 273 kept,
9 dropped. Everything is in `polish/`:

- `findings-verified.json`: by area, each finding with `id`, `kind` (bug, polish, slop,
  perf, a11y), `severity`, `title`, `file`, `line` (as of `6aa629b`), `evidence`,
  `user_impact`, `fix` (skeptic-corrected where needed), `files_to_touch`,
  `confidence`, `verify_reason`. Area summaries are in each entry's `summary`.
- `packages.json`: the same findings routed to nine file-owned packages so parallel
  fixers never edit the same file, plus `ownership` (paths per package), `order`,
  `effort`, and `deferred` (the three docs findings). Renames `slop-sweep-11` (Ora
  naming) and `slop-sweep-8` (injected script names) are excluded on purpose: do
  them last, alone, after everything else has merged.
- `route.py`, `merge-verdicts.py`: how those two files were produced.
- `fix-workflow.js`: the Workflow script that runs one fixer per package in an
  isolated worktree with build, targeted tests, lint and a commit. Read its prompt
  before writing a new one; the rules in it are the owner's style.
- `review-workflow.js`: adversarial review of the merged diff, reviewer plus
  skeptic per file group. Run it after the merge, before the docs pass.
- `merge.sh`: merges fix branches in order and stops at the first conflict.
- `smoke.sh`: keyboard-only runtime check of a Debug build with screenshots.

Package sizes, highest severity first inside each:

| Package | Findings | Owns |
| --- | ---: | --- |
| tabs-engine | 50 | Tabs state/models/browser delegate, BrowserEngine, downloads services, page tools, permissions |
| panels | 45 | History, bookmarks, downloads and files panels, extension views, passwords, importer, onboarding, error page |
| core | 41 | App layer (OraApp, OraRoot, OraCommands), shortcuts catalogue, windows, menus, BrowserView, window controls |
| sidebar | 28 | Sidebar, tab rows, drag and drop, split view, containers |
| design | 27 | Theme, styles, shared components (buttons, inputs, dialogs, toasts, icons, pickers) |
| urlbar | 26 | Address bar, toolbar, site info, page context menu |
| launcher | 22 | Launcher, home page, search engines |
| settings | 21 | Settings sections, glass |
| extensions | 8 | Extension services, injected scripts, bridge tests |

Must-fix bugs, by package:

- core: shortcut recorder both fires and records the key it captures and accepts
  Escape or a bare letter (`settings-1`, `shortcuts-menus-2/3`); seven Settings rows
  rebind shortcuts no command reads (`slop-sweep-2`, `shortcuts-menus-6`); five menu
  items hard-code chords (`slop-sweep-3`); Next/Previous Tab never switch and leave the
  switcher stuck (`shortcuts-menus-5`); ⌘W on two File items, Close Window wired to
  nothing (`shortcuts-menus-1`, `windows-chrome-5`); traffic lights lost with a second
  window or a right sidebar plus hidden toolbar (`windows-chrome-1/3`); the revealed
  sidebar's resize handle compounds its own translation (`sidebar-1`).
- tabs-engine: mailto:/tel:/app links show the error page (`engine-1`); HTTP basic auth
  refused (`engine-5`); JavaScript prompt() opens with no caret (`engine-6`); expired
  certificate has no way through (`engine-4`); geolocation never prompts (`engine-7`);
  window.open adoption builds and discards a web view (`tabs-state-1`); reopening a
  deleted pinned tab demotes it (`tabs-state-2`); ⌘1 to ⌘9 count a flat list while the
  sidebar shows folders (`tabs-state-3`); a refused SwiftData store ends in
  `fatalError` with nothing on screen (`tabs-state-8`).
- panels: File > Import Data's Safari and Chrome buttons do nothing and Arc reads a
  path the sandbox cannot see (`panels-2`); History "Clear" wipes a space with no
  confirmation and ignores the search (`panels-1`); "Move to Trash" drops the row even
  when trashing failed (`panels-7`).
- settings: Clear Cache/Cookies/History in Spaces run unconfirmed (`settings-2`);
  renaming a custom engine drops it as default (`settings-3`); the Extensions section
  persists a selection that leaves no row highlighted (`settings-5`).
- launcher: pages opened from suggestion rows get the fallback `DownloadManager`, so
  their downloads have no toast, no progress and no collision prompt (`launcher-1`);
  hover never highlights rows because the window never asks for mouse-moved events
  (`launcher-2`); suggestions get fresh UUIDs per keystroke so every row rebuilds
  (`perf-3`); history fetches 200 rows to show six (`launcher-4`).
- urlbar: ⌘L and ⇧⌘C dead in compact mode (`urlbar-toolbar-1`); no stop button
  (`urlbar-toolbar-3`); the "…" menu's zoom bypasses `SiteZoomController`
  (`urlbar-toolbar-4`); "Allow on home" offered for aura:// pages (`urlbar-toolbar-9`).
- design: Return chip dead on every dialog opened through `DialogManager.show`
  (`design-system-1`); Reduce Motion ignores the system setting (`a11y-keyboard-2`);
  secondary text loses contrast on glass chrome (`a11y-keyboard-3`).
- sidebar: rename fields take focus in the mounting update (`sidebar-2`); hover
  republishes `TabDragSession` and rebuilds the sidebar twice per row (`sidebar-3`);
  favicons re-fetched over the network per row (`sidebar-4`, `tabs-state-5`).
- extensions: a shim version bump rewrites an MV3 service worker into a file that
  imports itself (`extensions-scripts-2`).

Visual and slop themes that recur across packages: stock AppKit buttons, checkboxes and
text fields next to `OraButton`/`OraInput` (Search Engines, Spaces, Passwords vault,
error page, extension store, About box); three modal cards with 11/14 pt radii and a
20 pt shadow against the `AuraRadius`/`AuraShadow` rule; "esc" spelled out on Cancel
chips; "..." versus "…"; Title Case versus sentence case inside one card; about 870
lines of never-drawn icon art; a skull emoji as a data default; a grammar error in the
new-space explainer; onboarding copy that shames the user for declining ad blocking.

## Build, test, lint

Xcode is `/Applications/Xcode-beta.app`; `xcode-select` points at the command line
tools, so every xcodebuild and swiftlint call needs:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodegen generate     # Aura.xcodeproj is gitignored; every fresh checkout or worktree needs this
```

```bash
# Debug build, about 20 s warm, 30 s from scratch (M5 Pro, 18 cores). Always redirect and grep.
xcodebuild build -project Aura.xcodeproj -scheme aura -destination "platform=macOS" -configuration Debug \
  -derivedDataPath /tmp/dd-aura-main CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= > /tmp/build.log 2>&1
grep -E "^\*\* BUILD|: error:" /tmp/build.log

# Unit suite: build-for-testing about 60 s, the whole suite runs in 6 s.
xcodebuild build-for-testing -project Aura.xcodeproj -scheme aura -destination "platform=macOS" \
  -configuration Debug -derivedDataPath /tmp/dd-aura-main CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= > /tmp/bft.log 2>&1
xcodebuild test-without-building -project Aura.xcodeproj -scheme aura -destination "platform=macOS" \
  -derivedDataPath /tmp/dd-aura-main -only-testing:auraTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= > /tmp/test.log 2>&1
grep -E "Test run|failed" /tmp/test.log | tail

# WebKit-hosted suites, about 70 s, need the env var:
TEST_RUNNER_AURA_BUNDLE=1 xcodebuild test-without-building ... -only-testing:auraTests/WebBundleTests \
  -only-testing:auraTests/WebRequestBrokerTests -only-testing:auraTests/BrowserPageTests ...

swiftformat --lint <files>
swiftlint lint <files>        # crashes without DEVELOPER_DIR; pre-existing warnings are file_length/type_body_length
```

Baseline at `6aa629b`: 670 tests in 102 suites pass; 88 compiler warnings, all
Swift 6 isolation notes and `WKProcessPool` deprecations, none from this pass.

Lefthook pre-commit runs swiftformat and swiftlint --fix on staged Swift files. Commit
messages: `fix:`/`polish:`/`perf:`/`a11y:`/`chore:` prefix, no attribution trailers.

Parallel fixers: Workflow worktree isolation cuts worktrees from `main` (`042b2d4`),
not from the checked-out branch. `fix-workflow.js` therefore starts every agent with
`git reset --hard <base>`; keep that. Each agent needs its own `-derivedDataPath`;
nine concurrent fresh builds were fine on this machine.

## Running the app for checks

- The Debug bundle uses the real profile at `~/Library/Application Support/Aura`
  (`OraData.sqlite`; the tab table is `ZTAB`, columns `ZTITLE`, `ZURL`, `ZTYPE`,
  `ZORDER`). Quit the owner's own Aura first; `pgrep -lf Aura.app/Contents/MacOS/Aura`.
- The owner runs paneru, a scrolling tiling window manager, plus sketchybar. Any
  coordinate click through System Events lands on the wrong window and can switch
  virtual workspaces, including onto the owner's editor. Use keyboard only:
  `osascript -e 'tell application "System Events" to tell process "Aura" to keystroke "t" using command down'`,
  `key code 53` for Escape, `key code 36` for Return. `screencapture -x` for
  screenshots, then `sips -Z 1400` before viewing. Window position:
  `get position of window 1`. `polish/smoke.sh` is the sequence used here.
- Probe verdicts and bundle logs:
  `/usr/bin/log show --info --last 5m --predicate 'subsystem == "com.aurabrowser.app" AND category == "webbundle"'`
  (zsh has a `log` builtin; use the full path).
- Aura window under paneru: `window_focused` events with an empty title mean some
  Aura window other than the browser took focus.

## Suggested order

1. Fix per package with `polish/fix-workflow.js` (args: `base`, `file`, `order`,
   `counts`, `effort`, `ownership` as stored in `packages.json`), or by hand in the
   package order `tabs-engine, core, panels, sidebar, urlbar, design, launcher,
   settings, extensions`. Cross-owner edits are listed per finding under
   `cross_owners`; expect small merge conflicts in `OraCommands.swift`, `OraRoot.swift`,
   `TabManager.swift`, `BrowserView.swift`.
2. Merge with `polish/merge.sh`, full build, full suite, gated suites, `smoke.sh`.
3. Run `polish/review-workflow.js` over the merged diff (args: `base`, `groups` of
   changed files) and fix what survives.
4. Rename pass, alone: `OraApp`, `OraRoot`, `OraCommands`, `OraButton`, `OraInput`,
   `OraIcon(s)`, `OraBrowserScripts`, `URL+Ora` helpers (`oraHome`, `isOraInternal`,
   `oraSettings`, ...), the `ora-` injected script names and window globals (mirror
   in `scripts/*-bridge.test.cjs`), asset `OraColorLogo`, `ora-logo-plain`. Do NOT
   rename the store file `OraData.sqlite` or anything under `LegacyDataMigrator`.
5. Docs: delete `HANDOFF-MACOS.md` (owner's machine paths and team ID), drop the
   "target machine is the user's M5 Pro" sentence from `PERFORMANCE.md`, refresh
   `AUDIT.md` open findings and `ROADMAP.md` against what shipped, update README's
   feature and shortcut lists, then delete this file.
6. Release: `scripts/release.sh <version> --notes notes.md` builds, signs, writes the
   appcast and publishes; the owner runs it.
