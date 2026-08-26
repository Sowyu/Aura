# macOS handoff — full uBlock Origin: blank tabs + dead popup (branch `feature/extensions`)

Written on the Linux box, where none of this can be built or run. Everything below
was verified by reading; the checklist is what needs a real macOS build.
Background and root causes: `UBLOCK-ORIGIN.md`, "Status update, 2026-08-24".

Run notes from the first macOS pass are at the bottom ("Run notes, 2026-08-25").

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

## Run notes, 2026-08-25 (Aniko's Mac, Xcode 27.0 beta 27A5218g, macOS 27)

Done by the agent before handing the checklist back to a human:

- `xcodebuild -scheme aura build`: succeeds. Needs `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`, the active dir is CommandLineTools.
- `-only-testing auraTests`: the test target would not code-sign under Xcode 27 (no Info.plist). Fixed in `project.yml` with `GENERATE_INFOPLIST_FILE: YES` on `auraTests`, uncommitted. Result: 598 passed, 16 skipped, 2 failed. Both failures are environmental and untouched by this branch: `nativeFindWrapsPastTheLastMatch` (local socket bind, `Operation not permitted`) and `aFileNobodyStampedIsNotQuarantined` (temp file arrives quarantined). `FullUBlockOriginTests` all pass.
- Item 1 staged and half-verified. The pre-fix profile was rebuilt by hand: `privacy.fullAdBlocking=1`, `privacy.extensionRequestBlocking=1`, Lite in `extensions.disabledIDs`, `extensions.bundled.lite.pausedForFull=1`, and full uBO's consent hash set to the old scheme (pristine list + `nativeMessaging`, `7564ec8a…`). One launch later the record read `f00c5f05…` (pristine), Lite stayed paused, full stayed enabled, no consent sheet, `extensions.consent` otherwise untouched. That is the data half of the heal. The profile has been put back into the broken state, so the next launch of the Debug build reproduces item 1 again; the pre-staging backup is at `/tmp/aura-backup-115241` (prefs plist + Extensions folder).
- Not verified: the popup, the launch-time log lines (the first stream ran without `--info`; use `log stream --info --predicate 'subsystem == "com.aurabrowser.app"'`), and paint. What was seen on the ship config, one page on the bundle pool, with the window parked at x=1799 on an 1800 pt display (so treat as a hint, not a row result): the page's own `requestAnimationFrame` counter stopped at 2 and stayed there for 12 s while `document.visibilityState` stayed `visible`, and `adsbygoogle.js` loaded, so nothing was blocking. Then, after a `quit` AppleEvent that never completed, the log filled with `ublock-origin-full stopped answering; muted for 5s`. Whether the mutes started with the quit or were already the state of that session is unknown.
- `scripts/paint-probe.html` is the page used for that. Serve it with `python3 -m http.server 8765 -d scripts --bind 127.0.0.1`, open `http://127.0.0.1:8765/paint-probe.html?run=NAME`, and read the server's stdout: it logs a `/beacon?...&t=SECS&f=RAF_FRAMES&k=present|absent&vis=...&ad=...&fx=...` line every 2 s. `f` climbing past ~60/s means the page is still painting; `f` frozen means it stopped. `k` is the keep-alive marker (must be `absent` for item 7), `ad`/`fx` say whether the ad script got through. The 404 on `/beacon` is expected. This gives the Track 2 table a number per row instead of a screenshot.
- Second pass, same day: on the branch build the profile healed (hash migrated, no sheet) and pages were still blank, with Lite left paused, so the probe had said `painted`. Fixed in `AuraWebBundlePaintProbe.swift`: the fixture counts its own rAF frames, a control page on the ordinary service loads beside it, a bundle counter that stands still while the control's climbs is `blank` and outranks the snapshot, and the host window keeps one point on screen so rAF ticks at all. Reducers covered in `FullUBlockOriginTests`. Item 4 (fallback + rescue) is now the launch to watch: expect `paint probe verdict: blank (snapshot painted, frames bundle ~2 control ~120)` in the log, Settings showing the reason, Lite back, open tabs reloading onto the ordinary service.
- Live probe on this machine after the fix (`TEST_RUNNER_AURA_BUNDLE=1`, suite `auraTests/WebBundleTests`): `paint probe verdict: blank (snapshot painted, frames bundle 0 control 61)`. The gated `theBundleAnswersTheStartupProbe` now fails here on purpose: it asserts the stack is healthy, and on macOS 27 it is not. It is not part of the pre-push gate.
- Third pass, same day: root cause found and fixed. WebKit refuses to hold RunningBoard assertions for the Development WebContent service and its throttler then freezes the process's rendering; `AuraWebBundleSupport.m` now answers those assertions in-process for Development targets only (details and credits in `UBLOCK-ORIGIN.md`, "Track 2 result"). The paint probe reads `painted (frames bundle 120 control 121, screen painted)` on this Mac and the gated `theBundleAnswersTheStartupProbe` passes again. The Track 2 A/B rows above are moot: all four read blank, and both levers (`AURA_FG_PRIORITY`, `AURA_PAINT_KEEPALIVE`) are deleted. Items 1, 2, 5, 6 and 7 of the checklist are still yours to run by hand; item 3 is answered and item 4 was seen firing before the fix.

## Run notes, 2026-08-26 (same Mac, macOS 27, Xcode 27 beta; ad-hoc signed Debug build)

Build: `xcodebuild ... CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""`.
The only signing identity on this Mac is team 8TZ464JNCL, not the project's, and an
unsigned build has no sandbox and therefore reads the wrong profile
(`~/Library/Application Support/Aura` instead of the container). Ad-hoc keeps the
entitlements, so the container profile is what ran. First launch after the signature
change gets macOS's "differs from previously opened versions" prompt; Open Anyway.
Backup of the container profile before any of this:
`~/Library/Application Support/Aura-backups/2026-08-26-pre-extensions-run`.

Check 1 (popups with full ad blocking off), as shipped in 7c67777: the gate was not
the whole cause. With the shim unconditional the relay attaches on both ends
(`relay: background attached for <id>` at launch, and the popup's own hello reads
`shimVersion, role page, relay 1` in the `webrequest` debug log, which is the
`__auraShimInstalled / __auraShimRole / __auraShimRelay` check without opening the
inspector), and Bitwarden still sat on its spinner and DuckDuckGo stayed blank. A
diagnostic copy of the shim that forwards `error`, `unhandledrejection` and
`console.error` to the log found three separate causes, two of them in the
background pages rather than the relay:

1. Bitwarden's background gates every popup port on `port.sender.origin`
   (`senderIsInternal`), and the shim's page ports carried `{url, frameId}` only. Fixed
   in `senderInfo()` (aura-shim.js).
2. Bitwarden's background then died on `this.device.toString` (null): its browser
   detection wants a Safari, Chrome or Firefox token in `navigator.userAgent`, and
   extension web views reported WebKit's bare default UA. Fixed in `ExtensionEngine`:
   the controller's configuration now carries `BrowserPageConfiguration.oraUserAgent`,
   the same string tabs use. Bitwarden's popup renders (onboarding screen).
3. DuckDuckGo's background died at startup on
   `webRequest.OnHeadersReceivedOptions.EXTRA_HEADERS` (Chrome's option enums, which
   WebKit does not define). Fixed in the shim's webRequest namespace. Its background
   now starts, but the popup is still blank: on opening it, the background rejects
   `getPrivacyDashboardData` at `background.js:27139`, "unreachable - cannot access
   current tab with ID <n>", i.e. DuckDuckGo's own tab tracker has no record for the
   tab WebKit reports. That is a tabs/webNavigation-event gap, not the relay; not
   fixed here. Still open from the reading pass: the page half has no
   `runtime.onMessage` and the relay has no background-to-page broadcast, so a
   rendered Bitwarden popup will not hear sync/unlock events.

Shim version is 6 now; the first launch re-patches every folder (`shimmed extension
at <folder>` x5 seen) and every folder keeps its `manifest.original.json`. No consent
sheet on any launch.

Check 2 (extension pages in tabs): `ExtensionOrigin` holds. The dashboard opened at
`webkit-extension://17b7cf7d-d730-5b6b-ab4c-d3be2b761448/dashboard.html`, which is
exactly `ExtensionOrigin.host(for: "ublock-origin-full")`, and the restored tab came
back at the same address. But it failed in the same session too, before any relaunch,
with NSURLError -1008, and the retry could not help: WebKit's scheme handler
(`WebExtensionURLSchemeHandlerCocoa.mm`) serves an extension page as a main frame only
to a web view whose configuration carries `_requiredWebExtensionBaseURL` for that
extension, which only `WKWebExtensionContext.webViewConfiguration` sets, and such a
web view can show nothing else. So the third fork from the brief. Fixed: a tab whose
address is an extension page builds its `BrowserPage` on the context's configuration
(`ExtensionManager.pageConfiguration(hosting:)`), a main-frame navigation across that
line tears the web view down and rebuilds it (`Tab.rehost`, the same move aura://
pages already make; the back list goes with it), and the launch retry rebuilds instead
of reloading into the same web view. Rule in `TabBrowserPageDelegate.needsRehost`,
test in `BrowserPageTests`. Result: dashboard renders in the tab (settings, filter
lists, storage 20.3 MB), survives quit/relaunch (first visual layout 133 ms on the
restored tab), and reopens from the popup's gear. Seen once and not reproduced: the
very first restored load after the fix laid out but painted black until a reload.

Also fixed while here: `ExtensionManager.start()` only ran from the first
`BrowserPage`, so a launch onto aura://settings (or home) had no extensions at all:
no toolbar buttons, Lite's dashboard button disabled, and the blocker bookkeeping
(`pausedForFull`, `disabledIDs`) unreconciled until a page opened. `windowDidOpen`
starts it now; the engine was up 0.5 s after first paint with the Settings tab active.

Checklist status: 1 done (no sheet, full uBO loads, popup shows live stats: 25 blocked
on the page, 534 since install). 3 done, numbers in UBLOCK-ORIGIN.md. 6 partly:
dashboard yes, popup yes; element picker and per-site power button not exercised.
7 done with full off: Lite loads, the probe page paints (rAF ~60/s), `__auraKeepAlive`
absent, `adsbygoogle.js` blocked as script and as fetch, Lite's popup shows "optimal"
and a badge. 2, 4 and 5 not run: 2 needs a clean profile, 4 no longer has a lever to
force, 5 needs the extensions list driven by hand. Note for 7 on this profile: the
Lite folder was missing from the container although its "installed once" marker was
set; clearing `extensions.bundled.ublock-origin-lite` made the next launch unpack it.

Two things noticed and not touched: Cmd+Q and the `quit` AppleEvent hang three times
out of four (the process stays at 0% CPU with no dialog; SIGTERM was needed), and the
main window keeps being re-parked at the display's right edge (x = 3439 on a 3440 pt
display) after a popup closes.

## Run notes, 2026-08-27 (Bitwarden and DuckDuckGo popups, follow-up to the 26th)

Bitwarden's popup was already rendering after the 26th's origin and user-agent fixes;
what remained was that it could not hear the background afterwards. The relay now
carries the other direction too: the background's `runtime.sendMessage` goes out as a
broadcast frame to every open page port of that extension (`ExtensionMessageRelay`
keeps them in `pages`), each page dispatches it on a relay-backed `runtime.onMessage`
that both sides now install, the first page answer settles the background's promise,
and the host answers null itself when no page is open so nothing awaits forever. The
live round-trip test (`WebRequestBrokerTests.anExtensionPageReachesItsBackgroundPage`)
now drives both directions: page connect/echo/disconnect, page one-shot, background
broadcast heard by the page, page answer back at the background. Passes.

DuckDuckGo's popup was blank because its background threw "unreachable - cannot
access current tab with ID <n>" (`getPrivacyDashboardData`): its own tab table only
learns a tab from `tabs.onCreated`/`onUpdated`/`webNavigation.onBeforeNavigate`, and
none of those fired for the tab under the popup. Three causes, three fixes:

1. WebKit marks the tabs it finds at context load open with events suppressed
   (`populateWindowsAndTabs`), so launch-restored tabs were never announced.
   `ExtensionManager.announceOpenTabs(to:)` now reports every open tab as a property
   change once the extension's background is up (after the persistent-background
   wake), which lands as `tabs.onUpdated` and creates the record.
2. `tabDidActivate` now sends `didOpenTab` (a no-op when WebKit already knows the
   tab) and a property change before the activation, so tabs from other spaces and
   tabs back from hibernation stop being ids nobody has heard of. WebKit's own log
   showed the signature: "Invalid call to webNavigation.getAllFrames(). Tab not
   found."
3. An aura:// page matches no host pattern, so WebKit hid its URL and DuckDuckGo's
   table dropped the tab (Chrome shows chrome:// URLs to the `tabs` permission).
   `ExtensionTabAdapter.shouldBypassPermissions(for:)` returns true for internal
   tabs only; nothing runs in them, so the bypass exposes an address and no more.

Verified live: DuckDuckGo's popup renders on a launch-restored web tab (shows the
"Privacy Protections are not available for special pages or local pages" banner for
127.0.0.1, correctly), and Bitwarden still renders with the broadcast in place. Not
re-verified live one by one (the Mac's owner was using it by then): the popup on a
freshly opened tab and on an aura:// page after the bypass; both ride the same
record-creation paths the restored case proved. Shim version is 7 (the broadcast
went in after the 6 bump, so patched folders re-patch once more).

Still open, DuckDuckGo only: its background logs "Error loading https lists" and a
`TypeError: null is not an object (evaluating 'list.data.entities')`
(public/js/background.js:5300) while loading its tracker lists; the extensions page
shows it on the row. Separate from the popup path, untouched.

Also cleaned up: `bundledBlockersPopupAndDashboardRender` asserted
`openPortCount > 0` after uBO Lite's popup rendered, but that popup speaks in
one-shots whose tunnelled ports close on reply, so the assertion raced (it failed at
4851de6 too, before any of this). It now checks the popup's own relay flag.
