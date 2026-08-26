# macOS handoff — full uBlock Origin: blank tabs + dead popup (branch `feature/extensions`)

Written on the Linux box, where none of this can be built or run. Everything below
was verified by reading; the checklist is what needs a real macOS build.
Background and root causes: `UBLOCK-ORIGIN.md`, "Status update, 2026-08-24".

## Build

```sh
xcodegen            # project.yml changed nothing, but AuraPaintKeepAlive.swift is new
xcodebuild -scheme aura build
xcodebuild -scheme aura -only-testing auraTests test
```

New API, verified against WebKit trunk headers (not just memory), so compile
surprises should be limited to SDK lag:

- `WKWebExtension.hasPersistentBackgroundContent` — confirmed verbatim in
  `WKWebExtension.h`, and its docs note persistent background content is
  macOS-only, which is exactly the MV2-uBO case the eager wake targets.
- `WKWebExtensionContext.loadBackgroundContentWithCompletionHandler:` — confirmed;
  Swift async projection matches the existing `try await loadBackgroundContent()`
  call the repo already builds.
- `AuraSetAlwaysForegroundPriority` tries
  `_setClientNavigationsRunAtForegroundPriority:` first — confirmed in
  `WKWebViewConfigurationPrivate.h` as WK_API_AVAILABLE(macos(13.5)) with no
  platform guard, while `_setAlwaysRunsAtForegroundPriority:` is inside
  `#if TARGET_OS_IPHONE` (that's why it's only the fallback). Expect the launch
  log line `always-foreground priority applied`; `unavailable` would mean the OS
  build dropped the SPI.

The blocker state machine was also exhaustively model-checked off-box (complete
reachable state space, 374 states / 1990 transitions over every sequence of
switch/row/consent/relaunch/probe-fail/update actions): never both blockers
loaded, never zero blockers except by user choice or a queued consent sheet, the
steady state always loads full uBO, and the Privacy switch never clears without
a user-attributable cause. The same model with the pre-fix semantics reproduces
all three shipped bugs, so the pass is meaningful. What the model cannot cover
is WebKit runtime behavior — which is items 3, 4 and 6 below.

## Extension pages and popups (added after the first macOS run)

Two things the first real run turned up, both fixed here and both needing a build to
confirm:

1. **Every popup was talking to nothing.** The shim patch — which carries the
   page→background messaging relay as well as the blocking-`webRequest` bridge — was
   gated on the request-blocking setting, so with ad blocking off (the default) no
   extension got it and any popup that asks its background page anything sat there:
   Bitwarden on its spinner, DuckDuckGo blank. Patching is unconditional now. Check:
   with **full ad blocking off**, open the popup of a non-blocker extension and see it
   render; `log stream --predicate 'subsystem == "com.aurabrowser.app"'` should show
   `relay: background attached for <id>`. If a popup is still blank *with* the relay
   attached, the bug is in the relay itself, not the gate — read the popup's console
   through Inspect Element.
2. **Extension pages in tabs failed to load.** `WKWebExtensionContext` mints a random
   `baseURL` host per context and Aura only ever set `uniqueIdentifier`, so an
   extension's own origin changed on every launch and a restored dashboard tab pointed
   at an extension nothing answered for — Aura's "Something Went Wrong". The origin is
   now derived from the extension id (`ExtensionOrigin`), and a tab that asks for an
   extension page before the extension has finished loading retries for six seconds
   rather than reporting. Check: open uBO's dashboard in a tab, quit, relaunch — the
   restored tab has to come back, and the URL has to be the same one it was before.
   Tabs saved *before* this change still point at a dead origin and will not heal;
   reopen them once.

## Functional checklist, in order

1. **Profile heal (the reported bug).** On a profile that already has the broken
   state (full ad blocking on, uBO Lite paused, uBO full parked "waiting for you
   to review"): launch. Expected: no consent sheet, full uBO loads, its toolbar
   popup renders with live stats, `log stream --predicate 'subsystem ==
   "com.aurabrowser.app"'` shows the shim connecting and no "toolbar action
   ignored".
2. **Fresh enable flow.** Clean profile → Settings → Privacy → Full ad blocking
   on → consent sheet appears (now also over the browser window, not only in
   Settings) → approve → relaunch. Expected: full uBO active, Lite disabled,
   exactly one blocker at all times (check the extensions list), no second
   consent sheet.
3. **Paint.** With full uBO on: do pages still paint 5+ s after load, or do they
   blank ~1 s in? This is the Track 2 A/B — four launches:

   | AURA_FG_PRIORITY | AURA_PAINT_KEEPALIVE | expectation to record          |
   |------------------|----------------------|--------------------------------|
   | (default, on)    | (default, on)        | ship config — does it paint?   |
   | 0                | (on)                 | isolates the keep-alive        |
   | (on)             | 0                    | isolates foreground priority   |
   | 0                | 0                    | baseline: the old broken stack |

   Record the result per row in `UBLOCK-ORIGIN.md` Track 2 (that's the spike's
   deliverable). Also note whether `always-foreground priority applied` or
   `unavailable` is logged.
4. **Fallback + rescue.** In the `0 / 0` baseline (or if the ship config still
   blanks): the paint probe should now fall back — Settings shows the reason,
   uBO Lite comes back, and *already-open tabs reload onto the normal service*
   within a few seconds instead of staying blank. No blank tabs, ever, is the
   acceptance bar.
5. **Row-toggle sanity.** With full uBO running: disable its row in the
   extensions list → the Privacy switch turns off and Lite resumes. Re-enable
   the row → switch back on, pending relaunch. Toggling Lite's row on while full
   runs flips it back off — and Lite must NOT end up loaded anyway (the review
   caught a queued-load race here; verify only one blocker's dashboard opens and
   only one filters a test page). Declining any consent sheet and flipping the
   row again must re-raise the sheet, not silently no-op.
6. **Popup depth.** uBO popup: element picker, dashboard (six iframes deep), and
   per-site power button all work; changes stick after the popup closes.
7. **Regression.** With full ad blocking OFF (the default): uBO Lite still
   blocks, its popup still works, pages on the ordinary service, no keep-alive
   script in page sources (`__auraKeepAlive` must be absent), no consent sheets.

## If the probe now false-positives (falls back on a healthy stack)

The inconclusive-twice → fallback change trades a blank browser for a session of
Lite. If launches fall back on a stack that demonstrably paints, the probe's
first snapshot is failing for an environmental reason (offscreen window not
committing?) — look at `paint probe verdict:` logs, and consider ordering the
window on-screen at 1×1 px instead of at (-20000, -20000) before weakening the
fail-safe direction.
