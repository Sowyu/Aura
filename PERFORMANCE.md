# Performance work, 7 September 2026

Ten portable bridge tests pass. Native compilation and the favicon and media
regression tests passed on macOS CI. Full validation is still in progress.
There is no measured whole-browser CPU, memory or startup improvement yet.

## Work removed

The tests execute Aura's shipped scripts against instrumented DOM fixtures. Counts
below compare the scripts immediately before and after this performance pass.
They measure calls and messages, not rendering time or memory usage in WebKit.

| Workload | Before | After |
| --- | ---: | ---: |
| Focus a password in a form with 1,000 unrelated fields, geometry reads | 1,003 | 3 |
| Focus an unrelated field in that form, geometry reads | 1,002 | 0 |
| 100 scroll events before a repaint, geometry reads / native messages | 200 / 100 | 1 / 1 |
| 100 DOM mutation batches with unchanged media controls, capability messages including initialization | 101 | 1 |
| 100 DOM mutation batches after the last media element disappears, full media scans | 100 | 0 |

Autofill now checks field relevance before layout. Scroll and resize updates coalesce
at the next animation frame, carry the final geometry, and only notify native code
when the geometry changes. Hidden fields, disabled fields, field selection, document
isolation and password whitespace have regression coverage.

Media capability messages still report control changes and initialize newly playing
sessions. Removing the final media element disconnects the DOM observer and releases
the bridge's active-element reference. Media lifecycle events restart observation
when a player returns.

Animation-frame scheduling follows the browser's repaint cycle, documented by
[MDN](https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame).
The tests count work; actual display latency still needs WebKit verification.

## Native changes

- MediaController only runs its two-second fallback title timer while a live session
  is playing. Pause, removal and released tabs stop it. Playing sessions keep the same
  polling interval, and existing title-change notifications remain.
- Favicon display requests and file saves share an in-flight download and decode per
  domain. Cache publication happens once. Late requests can reuse the resulting bytes,
  and failed saves use the same download failure cooldown as display requests.
- Favicon atomic file writes run outside the main actor. Completion handlers return
  on the main actor. Original image bytes, display resolution and cache ceilings stay
  the same.

Native tests cover timer start/stop and title freshness, plus 20 display requests
concurrent with 20 saves sharing one download. They also check recovery after original
bytes leave the cache. Both regression tests passed on the Apple Silicon macOS
runner with Xcode 26.0.1 in [run 34094144077](https://github.com/Sowyu/Aura/actions/runs/34094144077).
That run failed a separate password isolation test, so it is not a passing release gate.

## Reproduce the checks

```bash
bash scripts/check-local.sh
```

The new performance assertions fail against the saved pre-change scripts. The four
existing password security regressions continue to pass after optimization.

On macOS, with the repository's build tools installed:

```bash
xcodegen
bash scripts/xctest-debug.sh
```

## Measure the browser fairly

1. Profile a Release build with the usual signing setup. Record hardware, OS, build
   revision, display refresh rate, extension versions and settings. Use the same
   loaded tabs and enabled features for both builds.
2. Record cold startup through the first usable page, tab switching, scrolling and
   large-form focus. Aura's existing StartupProfiler logs early phases; also include
   deferred work and page readiness. First `onAppear` alone is not a usable-page metric.
3. Use Instruments to capture CPU time, allocations and memory for Aura and its
   associated WebKit content, networking and GPU processes. Check physical footprint
   and retained allocations. Parent-process RSS alone omits much of a browser's cost;
   summing RSS can double-count shared pages.
4. Repeat the same workload five times and report the median and worst run. Include
   a 60-second idle interval, a fixed set of loaded tabs, media playback, and repeated
   tab/player open-close cycles. Record loaded-tab count and background activity so
   suspended work cannot masquerade as an efficiency gain.
5. Check page loading, interaction latency and feature behavior alongside resource
   use. A smaller cache that repeatedly downloads assets, a slower tab switch, missing
   extension filtering or stale controls does not meet the acceptance criteria.

The next optimization should come from those traces. The custom extension bridge's
synchronous waits and native favicon disk activity are candidates for measurement;
no further scheduling or cache changes are justified by these operation counts alone.
