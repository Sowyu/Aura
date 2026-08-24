# Handoff: finish and verify the tab-lag / close-button / launcher / space-icon changes

You are on a macOS machine with Xcode. The changes described below were written on a
Linux box and have **never been compiled** — no Swift toolchain existed there. Your job
is to build, fix any compile fallout, run the tests, and manually verify each change.

The work lives on the `fix/tab-lag-launcher-polish` branch (this file included);
`git diff main...fix/tab-lag-launcher-polish` shows the changeset. Commit your fixups
to the same branch, and merge into `main` only once the build and the full `auraTests`
suite are green and the manual checks below pass. Commit messages: match the repo's
`fix:`/`perf:` style; never add "Authored by Claude" / "Generated with Claude Code"
lines — a `Co-Authored-By: Claude` trailer is the only permitted attribution. Run
`lefthook install` once so the swiftformat/swiftlint/pre-push hooks actually run on
your commits (they could not run on the Linux side).

## Build and test

```sh
./scripts/setup.sh          # installs xcodegen/swiftlint/swiftformat via brew, generates Aura.xcodeproj
./scripts/xcbuild-debug.sh  # plain debug build
./scripts/xctest-debug.sh   # build-for-testing + auraTests (the pre-push gate; ~301 tests, all must pass)
```

`swiftlint` / `swiftformat` run via lefthook on commit; run `swiftlint lint aura/` once
manually since these edits were made blind.

## What was changed and why

### 1. New-tab lag (the big one)

Opening a tab from the launcher froze the UI: the WKWebView build, 2–3 synchronous
SwiftData saves, and two throwaway `DownloadManager` constructions (each a store fetch)
all ran inline inside the Enter keystroke, *before* the launcher dismissed — so the
whole stall showed as a frozen launcher panel.

- `aura/Features/Tabs/State/TabManager.swift`
  - `activateTab(_:persist:)` grew a `persist: Bool = true` parameter. Callers that
    save again themselves before returning (`addTab`, `openTab`, `closeTab`,
    `activateContainer`, `moveTabToContainer`) pass `persist: false` → **one** SQLite
    commit per user action instead of 2–3. All other call sites keep the default and
    are unchanged in behavior.
  - New lazy `fallbackHistoryManager` / `fallbackDownloadManager` (one per
    window-manager, built on first use) replace the per-call `HistoryManager(...)` /
    `DownloadManager(...)` constructions in `activateTab`, `openTab`, `duplicateTab`.
    `DownloadManager.init` runs a 50-row fetch, so this removes up to two store
    round-trips per tab open.
  - `openTab` no longer makes the second `restoreTransientState` call after
    `activateTab` — it was a guaranteed no-op (`browserPage != nil`) that still
    evaluated a fresh `DownloadManager` default argument. The tab carries its managers
    from `Tab.init`, so `activateTab`'s restore uses the right ones. `loadSilently`
    (currently unused by any caller) still restores in the non-focused branch.
- `aura/Features/Launcher/LauncherView.swift` (`onSubmit`) and
  `aura/Features/Launcher/State/LauncherViewModel.swift` (typed-URL row, history row,
  AI-engine row, open-tab row): the launcher now sets `showLauncher = false` first and
  runs the tab-opening work in a `DispatchQueue.main.async` block, so the dismissal
  paints before the WKWebView build stalls the main thread. Values the deferred block
  needs (`currentText`, `isPrivate`, the managers) are resolved eagerly because
  `viewModel.reset()` clears state when the panel unmounts.
- `aura/Features/Sidebar/Views/TabList/NormalTabsList.swift`: `shouldAnimate` did two
  linear scans per row (O(n²) per list rebuild). Replaced by two `[UUID: Int]` index
  dictionaries built once per `body` evaluation and a `hasMoved` lookup. Foldered tabs
  keep the old always-`true` behavior.
- `aura/Features/Tabs/State/TabSearchingService.swift`: decorate-sort-undecorate so
  `combinedScore` runs once per tab instead of O(n log n) times per launcher keystroke.
- `aura/Core/BrowserEngine/BrowserEngine.swift` + `aura/App/OraRoot.swift`
  (`scheduleDeferredWork`): new `BrowserEngine.warmUp()` — a throwaway empty `WKWebView`
  created after first paint and held ~10 s, so WebKit's XPC services are up before the
  first real tab. Matters for the launch-onto-start-page case where the first ⌘T
  otherwise pays for the whole stack.

**Verify:** profile ⌘T → Enter with Instruments (Time Profiler / Hangs) before and
after if you want numbers; at minimum, the launcher should visibly dismiss immediately
on Enter, with the new tab's row + spinner appearing right after. Check a *background*
open (`⌘-click` a link / "Open in background" from the page context menu) still works —
those go through `focusAfterOpening: false` and must not build a web view. If
`warmUp()` shows no measurable win on first-tab open, it's fine to drop it; it's
self-contained.

### 2. Close button unresponsive

Two real causes, both fixed:

- `aura/Features/Tabs/Views/TabItem.swift`: the X was `allowsHitTesting(isHovering)`.
  When rows slide up under a stationary pointer after a close, `onHover` doesn't
  re-fire, `isHovering` stays false, and the click *selected* the tab instead of
  closing it. The button is now always hit-testable (still invisible until hover).
  Trade-off: clicking the empty trailing 20 pt slot of a row you haven't "hovered"
  closes rather than selects — that's the rapid-close case users actually hit.
- `aura/Features/Tabs/DragAndDrop/TabDragSourceView.swift` (+ `NormalTabsList` /
  `PinnedTabsList` passing `trailingClickWidth: 28`): the drag monitor armed a drag on
  mouse-down anywhere on the row, and ≥4 pt of pointer travel cancelled the button's
  press and started a tab drag. Presses inside the trailing 28 pt strip (20 pt button
  slot + 8 pt row padding) no longer arm a drag. Middle-click close is unaffected
  (separate hit-test). `closeTab` also saves once instead of twice (see §1).

**Verify:** rapid-close a stack of tabs by clicking the X repeatedly without moving
the mouse — every click should close. Sloppy-click the X (press + small move +
release) — should close, not start a drag. Dragging a tab by its title/favicon still
works; dragging from the far-right edge of a row intentionally does not. Also check
`auraTests/TabDragGhostTests.swift` still passes (it drives `pressedSource` directly).
Known pre-existing quirk left alone: a *pinned* tab with no live web view shows
"unpin" in the close slot (`TabItem.swift` `actionButton`), so the same pixel can mean
unpin — not part of this fix.

### 3. ⌘T shows the launcher on any page, including the homepage

⌘T posts `.showLauncher` (it is not a "new tab" event); three `activeTab != nil`
guards suppressed it on the zero-tab start page. All three are removed:

- `aura/App/OraRoot.swift` — the `.showLauncher` window-event handler.
- `aura/Features/Browser/Views/BrowserView.swift` — the mount condition.
- `aura/Features/Launcher/LauncherView.swift` — `dismiss()`, plus the now-obsolete
  `onDisappear` block that force-reset the flag when the last tab closed (its premise
  was the mount condition that no longer exists).

**Verify:** close every tab in a space (start page shows) → ⌘T opens the launcher
overlay, typing + Enter opens the tab; Escape and click-away dismiss it; ⌘T toggles
it closed. Watch one focus edge: with the launcher open **over the start page**,
⌘-Tab away and back — the homepage's embedded field uses a first-responder lock
(`LauncherTextField.swift` `wantsFocus` is set and never unset, and
`AuraWindow`'s `didBecomeKey` observer re-asserts it) that may yank focus from the
overlay's field after an app switch. If typing goes to the wrong field after an app
switch, that lock is the place to fix (clear `wantsFocus` when the pulse ends, or
skip the re-assert while `appState.showLauncher` is true). It's pre-existing (same
setup as an `aura://home` tab), so only fix it if it actually reproduces.

### 4. Default space icon is a heart

- `aura/Core/Constants/ContainerConstants.swift`: new `defaultIconSymbol = "heart"`.
  `"heart"` is in `SpaceIconCatalog` (bundled `heart.svg`) *and* is a valid SF Symbol —
  both render paths work (sidebar uses the SVG catalog; menus draw `iconSymbol` via
  `Image(systemName:)` directly). Don't switch to `"heart.fill"`: no bundled SVG.
- `aura/Features/Tabs/State/TabManager.swift` `createContainer` defaults now reference
  the constants (covers first launch, last-space-deleted recreate, restore fallback).
- `aura/Features/Sidebar/Views/BottomOption/NewContainerButton.swift`: the New Space
  dialog's `iconSymbol` state seeds with the heart, so the dialog pre-selects it (this
  also makes `SpaceIconPicker` open on its Icons tab instead of Emoji — expected).

**Verify:** delete all spaces (or fresh app-container run: the app's data lives in
`~/Library/Application Support/` under the `com.aurabrowser.*` bundle id) → the
auto-created "Default" space shows a heart in the space header and switcher; New Space
dialog shows a heart pre-selected; `auraTests/SpaceIconTests.swift` passes. The frozen
V1 schema copy in `aura/Core/Extensions/AuraSchema.swift` was intentionally left
untouched — do not "fix" its defaults.

## Most likely compile-fixup spots

Written blind; if the build breaks it will be here:

- `Dictionary(_:uniquingKeysWith:)` + `let` bindings at the top of `NormalTabsList.body`
  (result-builder context).
- The `@ObservationIgnored private lazy var` pair on `TabManager` (`@Observable` macro).
- `BrowserEngine`: `@MainActor` members on a non-isolated class + `Task { @MainActor … }`
  (project is Swift 5.9 language mode, so at most warnings).
- Argument label `previously:` on `hasMoved` and the new `trailingClickWidth:` label on
  `tabDragSource` call sites.

## Deliberately not done (candidates if more speed is needed)

- `ExtensionTabAdapter.pruneStaleAdapters()` rebuilds its dictionary on every tab
  open/activate — left alone; it's the safety net for bulk deletions (see
  `AUDIT-DEEP-ISSUES.md` item 4, which is the proper fix).
- `ContainerView`'s four filter+sort passes over `container.tabs` per render.
- A real `BrowserPage` pool / pre-built spare page (config is per-space, so pooling
  needs a key; the biggest remaining win for warm new-tab cost).
- Private tabs get a fresh `WKWebsiteDataStore` per tab (`BrowserEngine.makeProfile`).
- `deleteIfPresent`'s `fetchCount` per close (correctness guard, cold-ish).
- Everything in `AUDIT-DEEP-ISSUES.md` — separate work stream, unrelated to this pass.
