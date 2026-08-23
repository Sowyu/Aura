# Deep Audit: Architectural Issues Requiring Fixes

You are working in the Aura macOS browser codebase (SwiftUI + SwiftData + WebKit).
This document lists eight deep, hard-to-reproduce problems found by audit. They are
ordered by priority. Fix them in order unless instructed otherwise. Do **not** commit;
leave all changes in the working tree.

Context you need before starting:

- Every window builds its own `TabManager`, `HistoryManager`, `DownloadManager`, and
  `ModelContext` over one shared `ModelContainer` (`aura/Core/Extensions/ModelConfiguration+Shared.swift`).
- Extensions get a blocking `webRequest` via a WebKit injected bundle
  (`auraWebBundle/AuraWebBundle.m`) that parks the WebContent process on a synchronous
  IPC ask; `aura/Features/Extensions/Services/WebRequestBroker.swift` answers it from the
  UI main thread by spinning a custom run-loop mode while waiting for the extension.
- Build and test with:
  `/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild build-for-testing -scheme aura -destination "platform=macOS" -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
  then `test-without-building ... -only-testing:auraTests`. All 301 tests must pass
  after each fix. Tests are Swift Testing (`@Test`) plus some XCTest.

---

## 1. Requests bypass blocking webRequest while another verdict is pending

**File:** `aura/Features/Extensions/Services/WebRequestBroker.swift` (`decide()`, ~line 227)

**Problem:** The re-entrancy guard `guard !isDeciding else { return ["cacheable": false] }`
returns a verdict with no `cancel` field, which the injected bundle treats as *allow*.
Pages fire subresource loads concurrently; every request arriving while another decision
is in flight is admitted without consulting any extension. On ad-heavy pages this makes
blocking probabilistic rather than deterministic — the core feature's promise breaks
under exactly the load where it matters most.

**Fix direction:** Queue re-entering requests instead of allowing them. Cap the queue
depth (e.g. 32) so a pathological page cannot build an unbounded backlog; overflow
entries may be allowed but must be marked non-cacheable. When the in-flight decision
completes, drain queued requests through the normal decide path. Keep the existing
timeout/mute machinery per queued entry. Add unit tests: concurrent decides serialize,
queue drains after completion, overflow behaves.

## 2. Re-entrant WebKit API calls during the synchronous IPC reply

**Files:** `aura/Core/BrowserEngine/AuraWebBundleSupport.m` (sync message handler),
`aura/Features/Extensions/Services/WebRequestBroker.swift` (wait loop)

**Problem:** The UI process spins `CFRunLoopRunInMode(Self.waitMode, ...)` while replying
to the bundle's synchronous message. `waitMode` is registered in common modes, so all
common-mode sources fire mid-spin — including WebKit's own IPC (navigation delegate
callbacks, script messages, download callbacks from other tabs). Those paths call back
into WebKit APIs while parked inside a synchronous message reply, which WebKit does not
guarantee to tolerate. Probabilistic deadlocks/assertions with ≥2 live web processes.

**Related stall:** the windowless JS-alert fallback still uses `runModal()`
(`aura/Features/Tabs/Browser/TabBrowserPageDelegate.swift`, `present(...)`) which blocks
the whole UI thread — including any parked sync ask from another process — until dismissed.

**Fix direction:** During the wait, run only the sources needed for the reply (the
message-port source), not the full common mode — or move the verdict wait off the main
thread onto a dedicated waiter thread that owns the port and hands the answer back. For
the alert fallback, prefer attaching to any visible window over `runModal`; keep
`runModal` only as a last resort and document the stall. Add a regression test for pure
logic if testable; otherwise verify manually with two windows + uBlock.

## 3. Cross-window mutations of the shared store have no consistency handling

**Files:** `aura/App/OraRoot.swift` (one `ModelContext` per window),
`aura/Features/Tabs/State/TabManager.swift`

**Problem:** Window A can delete a tab that is window B's `activeTab`. Nothing notifies
B. B keeps rendering a deleted model, `isActiveInAnyWindow(_:)` keeps exempting the ghost
from hibernation, and two windows' maintenance passes can issue double
`modelContext.delete` on the same model from different contexts (undefined behavior).

**Fix direction:** Observe saves across contexts (SwiftData posts per-context save
notifications) or add an app-level notification posted by every destructive path
(`closeTab`, `deleteContainerContents`, `removeOldTabs`, `autoClearContainerTabs`).
On notification, each window reconciles: drop deleted ids from `activeTab`,
`recentlyClosedTabs` snapshots, `hibernating`, and reselect via `neighbour(after:)`.
Guard all second-pass deletes with a fetch-first check. Add tests replaying:
delete-in-A-while-active-in-B.

## 4. Static adapter cache leaks tabs deleted outside `closeTab`

**File:** `aura/Features/Extensions/Services/ExtensionTabAdapter.swift` (static `cache`),
called from `aura/Features/Extensions/Services/ExtensionManager.tabDidClose`

**Problem:** Adapters are pruned only via `tabDidClose`. But
`TabManager.deleteContainerContents` bulk-deletes tabs without notifying the extension
layer, and `applyLaunchTabPolicy` bulk-deletes at launch. Adapters accumulate forever,
and `WKWebExtensionController`'s open-tab state drifts from reality after space deletion
(breaks `tabs.query` semantics).

**Fix direction:** In `deleteContainerContents`, call
`ExtensionManager.shared.tabDidClose(tab)` (or a batch variant) for each tab before
deletion; same for `applyLaunchTabPolicy` when adapters may exist. Also prune
`ExtensionTabAdapter.cache` entries whose `tab` is nil wherever the cache is read.

## 5. Password keychain items sync off-device by default

**File:** `aura/Features/Passwords/Services/PasswordManagerService.swift` (`upsertCredential`)

**Problem:** New items are added with `kSecAttrSynchronizable: kCFBooleanTrue` and
`kSecAttrAccessibleAfterFirstUnlock`. Every saved credential silently propagates via
iCloud Keychain to every device on the Apple ID — including devices without Aura — with
metadata (host, username, container UUID) riding along unencrypted-in-practice.

**Fix direction:** Default to `kSecAttrSynchronizable: false` and expose "Sync passwords
via iCloud" as an explicit opt-in setting in Settings → Passwords. Existing synced items
should stay untouched (migrating them silently would surprise users); the setting only
affects new/upserted credentials. Note the change under Settings → About if a changelog
entry exists.

## 6. Extension installs are silent and grant everything

**Files:** `aura/Features/Extensions/Services/ExtensionEngine.load(directory:id:)`
(grants all requested permissions/patterns at install),
`ExtensionManager.installFirefoxAddon` / `installArchive` (no confirmation UI)

**Problem:** Installing an extension grants every requested permission and match pattern
with no user-visible consent, the shim rewrites the manifest on disk to add native
messaging, and AMO `.xpi` downloads install without any prompt. One malicious listing =
silent full access to every page in every space.

**Fix direction:** Before `engine.load` completes for a *newly installed* extension
(not re-enable of an already-trusted id), present a confirmation sheet listing display
name, version, source (folder / .crx / AMO guid), and the requested permissions in human
form (reuse `ExtensionCompatibility.evaluate`). Persist consent per extension id +
version; re-prompt when requested permissions grow. Gate `installFirefoxAddon` behind
the same sheet. Keep headless loading for extensions already consented.

## 7. No runtime health check for the private-API injected-bundle stack

**Files:** `aura/Core/BrowserEngine/AuraWebBundleSupport.m`, `AuraWebBundle.swift`,
`WebRequestBroker.swift`

**Problem:** The whole blocking-webRequest feature rests on transcribed private symbols
(`_WKProcessPoolConfiguration.injectedBundleURL`, `_apiObject`,
`WKContextSetInjectedBundleClient`, `WKBundlePostSynchronousMessage`) and on hosting
pages in the Development WebContent service. A half-changed OS update degrades behavior
subtly (stalled loads, muted extensions) with no signal.

**Fix direction:** At startup when `AuraWebBundle.isEnabled`, perform a round-trip probe:
post a state message to the pool and expect the bundle's synchronous echo within a short
deadline (the bundle side can reply to an existing message name; add one if needed). If
the probe fails, log prominently, set a flag that forces `extensionRequestBlocking` off
for the session, and surface once in Settings → Privacy ("Blocking webRequest
unavailable on this OS version"). Also assert the Development-WebContent caveat in the
settings copy.

## 8. Schema evolution relies on implicit lightweight migration

**Files:** `aura/Core/Extensions/ModelConfiguration+Shared.swift`,
`aura/App/OraRoot.openStore`

**Problem:** Two model-graph changes shipped (browsing containers entity, spaces no
longer cookie jars) relying on SwiftData lightweight migration. Lightweight migration
fails unrecoverably on certain relationship changes, and today that surfaces as
fatal-at-launch with the store intact but the app unusable.

**Fix direction:** Adopt `SchemaMigrationPlan` with explicit stages from the current
shipping schema forward. Export a fixture store from the shipping build and add a test
that opens the fixture through every migration stage. Keep `openStore`'s retry-once
behavior as the last resort, but log the underlying error into Application Support
(e.g. `last-store-error.txt`) before failing so users can report it.

---

## Working rules

1. One fix per logical changeset; do not interleave unrelated edits.
2. Build + full `auraTests` suite green after each item before moving on.
3. Where a fix touches `WebRequestBroker`, extend `auraTests/WebRequestBrokerTests.swift`;
   the existing suites there show the established style (pure-logic tests, no real IPC).
4. Do not alter the injected bundle's wire protocol (message names, JSON shape) — the
   ObjC side in `auraWebBundle/` must stay byte-compatible unless item 7 explicitly
   adds a new message name, which is the only sanctioned protocol addition.
5. Match the codebase conventions: doc comments explaining *why*, `saveOrLog` for
   SwiftData saves, no force unwraps outside tests.
