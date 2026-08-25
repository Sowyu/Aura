# How Aura ships uBlock Origin (full)

Status: Track 1 shipped and hardened (2026-08-24); Track 2's two most promising
levers are in the code behind env switches, awaiting A/B on a real macOS build
(`HANDOFF-MACOS.md`). Track 3 remains the endgame.

## Status update, 2026-08-24: why the shipped Track 1 presented as broken

Two chained failures, both fixed on this branch:

1. **The re-consent trap (dead toolbar icon, no blocker at all).** Consent was
   hashed over the *patched* manifest's permission list. Enabling full uBO
   installed it unpatched (the shim gate read the launch-latched bundle flag),
   the user consented to that hash, and the next launch's scan patched the
   manifest (adding `nativeMessaging`) — hash drift, so the loader silently
   parked full uBO on the consent queue while the blocker plan (which only
   nil-checked the consent record) had already paused uBO Lite. Result: no
   blocker, a toolbar icon whose click was a silent no-op, and every page on the
   Development service. Fixed by hashing consent over `manifest.original.json`
   (the shim's entries are Aura's business, not something the user answers for),
   patching at install based on the *persisted* setting, aligning the plan's
   consent input with the loader's decision, and hosting the consent sheet in
   the browser window rather than only in Settings.
2. **The paint probe failing open.** `painted` and `inconclusive` both counted
   as healthy, the probe raced tab restore (restored tabs landed on the bundle
   pool before any verdict), and a failed verdict could not rescue pages already
   on the pool. Fixed: inconclusive retries once and then falls back, the paint
   stage runs for every bundle session (not only full uBO), and `markUnavailable`
   now rebuilds every loaded web view so live tabs leave the broken pool instead
   of staying blank for the session.

Also shipped: MV2 persistent backgrounds are woken at load (uBO's `webRequest`
listeners and the popup's message relay only exist once the background runs; MV3
workers stay lazy), the vendored `ublock-origin-full` folder is replaced when its
version drifts from the pin, and the popup path's silent error exits are logged.

Track 2 levers now in code, both on by default on the bundle pool and switchable
per session for the A/B: `AURA_FG_PRIORITY=0` (WebKit's
`_alwaysRunsAtForegroundPriority` on page configurations, aimed at the failed
foreground assertion itself) and `AURA_PAINT_KEEPALIVE=0` (a one-pixel
`requestAnimationFrame` loop that keeps rendering updates committing, since the
measured purge left on-demand rendering intact). The paint probe runs with the
same keep-alive real pages get, so its verdict is about the mitigated stack.

## Goal

Full uBlock Origin available in Aura as an opt-in blocker, without regressing page
painting for users who never enable it, and without breaking uBlock Origin Lite for
users who keep that.

## Why full uBO is not shipped today

Aura already tried. The chain of facts, all verified in this codebase:

1. Full uBO blocks by registering a blocking `webRequest` listener. WebKit's native
   extension support gives hosts observe-only events, so Aura built the synchronous
   bridge: an injected bundle (`auraWebBundle/`) parks each resource load inside
   WebContent and asks `WebRequestBroker` over sync IPC.
2. Loading an injected bundle makes WebKit route pages to its *Development* WebContent
   service (`shouldAllowNonValidInjectedCode` — a third-party binary outside /System can
   never qualify for the regular service).
3. That Development service cannot take RunningBoard foreground assertions, and its
   layers get purged roughly a second after first paint. Pages stop painting.
4. So the bundled blocker was swapped to uBlock Origin Lite, whose
   `declarativeNetRequest` rules WebKit compiles and enforces itself — no bundle, no
   regression (`BundledExtensions.swift`, including the legacy-folder removal path).

Any plan for full uBO must break at least one link in that chain. Three tracks below,
in ship order.

## Track 1 — ship: opt-in full uBO behind the bundle, with automatic paint-fallback

This is the near-term answer and needs no new WebKit knowledge. It accepts the
Development-service trade-off but fences it so tightly that only users who asked for
full uBO ever touch the fragile stack, and nobody stays stuck on a broken one.

**Distribution.** AMO has deprecated MV2 listings, so fetch full uBO from its own
releases: `https://github.com/gorhill/uBlock/releases`, pinned version recorded in one
constant next to `SHIM_VERSION`, SHA-256 of the `.xpi` recorded beside it, verified
before unpack. Unpack verbatim into the extensions directory under the existing
install pipeline — no source modifications beyond the existing shim patch, which is
already how every extension is treated. Vendoring the archive into the app bundle like
uBOLiteRedux is also acceptable (and makes first enablement offline-capable); if
vendored, record the same pin + hash in-tree so CI can verify the blob matches upstream.

**Licensing.** uBlock Origin is GPL-3.0. Shipping unmodified binaries is compliant;
add it to `THIRD_PARTY_NOTICES.md` with a link to the corresponding source release
(the pinned tag URL satisfies the source offer). Do not patch uBO's own files beyond
the generic shim entry-point insertion every extension gets.

**Consent UX.** Unlike uBOLiteRedux, full uBO is NOT pre-consented: enabling it changes
the rendering stack for every page, which is a bigger deal than installing a filter
list. Settings → Privacy grows one row, "Full ad blocking (uBlock Origin)":

- Off (default): uBOLiteRedux handles blocking through DNR, exactly today.
- On: flips `extensionRequestBlocking` on (next-launch effect, matching the existing
  setting semantics), installs/loads full uBO, and disables uBOLiteRedux while enabled —
  running both double-filters and their rule sets fight. Re-enabling Lite when full is
  turned off restores it via the existing marker machinery.
- The row carries one honest sentence about what "on" does ("routes web pages through a
  compatibility mode required for request-level blocking").

**Paint health gate.** Extend the existing `AuraWebBundle.probe()` with a second,
visual stage that runs whenever full uBO is enabled: load a fixture page on the bundle
pool, wait ~2 s past first paint, `takeSnapshot`, and check it is not uniformly blank.
Blank ⇒ call the existing `markUnavailable(_:)`, which already forces
`requestBlockingUnavailable` for the session; the enable-row then reads unavailable and
uBOLiteRedux re-enables automatically. This turns the historical silent failure
("pages stop painting") into a bounded, self-healing event a user sees once, with an
explanation, instead of a browser that looks broken.

**Tests.** Pure-logic tests in the established style: pin/hash verification, the
enable/disable state machine (full-on ⇒ lite-off and back), consent gating, and the
probe verdict reducer. The visual probe itself is manual-verified per OS beta.

## Track 2 — spike: make the Development service paint reliably

One engineering spike (timeboxed, max ~2 days) aimed at the root cause, because if it
yields, Track 3 shrinks dramatically.

Knowns: the Development service fails to acquire RunningBoard foreground assertions
(`com.apple.runningboard.assertions.webkit` is Apple-only), and task-state propagation
to the rendering process is what purges layers. Things worth measuring before writing
this off:

1. Does the layer purge reproduce on the current macOS beta with the current SDK, or is
   the comment stale? (The probe fixture from Track 1 answers this in minutes.)
2. Does keeping the window key/occluded=false change it? Is it occlusion-driven?
3. Does `_WKProcessPoolConfiguration` expose anything new in the beta SDK (dump the
   private headers each release — the file already exists for transcription)?
4. If purge persists: does an explicit `webView.layer?.needsDisplay` heartbeat on a
   timer keep content alive well enough to pass the paint probe? Ugly, but if it works
   it converts "broken" into "costs a little CPU", which is a user-choice again.

Output of the spike: one paragraph in this file stating measured results and whether
Track 1's warning copy can be softened.

## Track 3 — endgame: blocking without injected code

The durable fix removes the bundle from the request path entirely. Two candidate
mechanisms, in preference order:

1. **Async UI-process interception.** A private hook that reports each resource load to
   the host asynchronously (delegate-style, like the sync client but non-blocking)
   would let the broker cancel/redirect without parking the web process — regular
   WebContent service, normal painting, and the 150 ms main-thread stall disappears
   with it. Feasibility spike: dump the beta SDK's private WebKit headers for any
   resource-load delegate on `WKWebsiteDataStore`/`WKProcessPool`; prototype
   cancel + redirect against a fixture page. If it exists, the broker's verdict logic
   (`WebRequestVerdict.merge`, mute/gate machinery) ports almost unchanged — only the
   transport changes from sync-reply to callback-with-id.
2. **Rule compilation.** Translate uBO's filter lists into `WKContentRuleList` rules
   (WebKit compiles and enforces them natively, same engine DNR uses). This loses
   uBO's dynamic and cosmetic filtering depth but delivers most real-world blocking
   with zero private API. Worth building regardless as a fallback blocker for users on
   macOS versions where Tracks 1–2 fail.

## Acceptance criteria

- Enabling full uBO installs, consents, loads, and blocks ads on a fixture ad page.
- With the bundle stack broken by an OS update, enabling degrades to: probe fails,
  uBOLiteRedis auto-restores, one clear message. No blank tabs, ever.
- Disabling full uBO restores uBOLiteRedux and the regular WebContent service on next
  launch.
- Pinned version + hash in tree match the GitHub release; notices updated; no uBO
  source files modified beyond the standard shim entry point.
