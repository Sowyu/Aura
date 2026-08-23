# Mission: Make Aura Daily-Drivable

You are working in the Aura macOS browser (SwiftUI + SwiftData + WebKit, repo root
`/Users/aniko/Documents/Subjected/Aura`). The engine layer is solid: blocking webRequest
via an injected bundle, WKWebExtension hosting with a consent gate, a keychain password
vault with autofill, spaces and browsing containers, tab hibernation, downloads,
history, find-in-page on `WKWebView.find`, a launcher, private windows, per-space
privacy, and an explicit schema migration plan. Three audit rounds have closed every
known correctness bug; CI builds and runs 324 unit tests.

What Aura is not yet is a browser someone can switch to from Safari or Chrome and never
open the old one again. This document is your work order for closing that gap. It lists
the missing surface area in priority order, with enough architectural grounding that you
can implement each item without re-deriving context. Work top to bottom: the ordering is
by how fast a new user hits the wall.

Build/test gate for everything below:
`/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild build-for-testing -scheme aura -destination "platform=macOS" -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
then `test-without-building ... -only-testing:auraTests`. All tests green after every
workstream. Do not commit; leave changes in the working tree.

---

## 1. Bookmarks and reading list (the single biggest gap)

There is no bookmark system. Users can pin tabs and favourite tabs, but nothing survives
"close it and find it later." A daily driver cannot ship without this.

Create `aura/Features/Bookmarks/`:

- **Model**: a SwiftData `Bookmark` entity (id, title, urlString, folder relationship,
  createdAt, order) added to `AuraSchemaV3` with a `MigrationStage.lightweight` step.
  Follow the established pattern in `aura/Core/Extensions/AuraSchema.swift`.
- **Manager**: `BookmarkStore` mirroring `HistoryManager`'s shape (`@MainActor`,
  `@Observable`, bounded fetches, `saveOrLog`). Support nesting one level deep only —
  folders of bookmarks, no folders of folders. Chrome parity is not the goal; Firefox's
  flat-with-folders model fits the existing sidebar folder UI better.
- **UI**: a bookmarks bar under the toolbar (`TopToolbar.swift` already reserves the row
  geometry), a manager view reachable from Settings and ⌥⌘B, "Add Bookmark…" (⌘D)
  writing title/favicon straight off the active tab, and context-menu actions on rows.
- **Reading list**: reuse the same entity with an `isUnread` flag rather than building a
  second feature. Unread items render bold; opening marks read.

Acceptance: ⌘D saves, ⌘⇧B toggles the bar, drag from address field onto the bar works,
bookmarks open respecting `externalLinkTarget` and site-to-space rules
(`TabBrowserPageDelegate.routeToRuleSpace` must see them like any navigation).

## 2. Session persistence and crash recovery

Today only URLs persist across launches — the WebKit back/forward list, scroll position,
and form state all die with the process, and there is no crash detection.

- Persist per-tab back/forward entries: on `BrowserPageDelegate.didUpdateNavigation(.finished)`
  serialize `webView.backForwardList.backList + currentItem + forwardList` (title, URL,
  and `WKBackForwardListItem` has no snapshot API, so store URL+title pairs only) into
  a JSON blob on the Tab row (new attribute via V4 migration). On
  `restoreTransientState`, rebuild by loading entry 0 and replaying
  `goForward()`-style loads silently, capped at ~20 entries so restore stays fast.
- Scroll restoration exists for hibernation (`hibernatedScrollOffset`); extend it to
  persist across relaunch for the N most recent tabs.
- Crash marker: write `.clean-exit` on `NSApplication.willTerminate`; if it is present
  at launch, show a one-line bar offering "Restore previous session" before
  `applyLaunchTabPolicy` deletes anything.
- Wire `failedResumeData` (`DownloadManager`) to real resume buttons now that retry
  exists — the data is already captured and stored.

## 3. Per-site browsing fundamentals

Three gaps every user hits within an hour:

- **Per-site zoom**: intercept `webView(_:didFinish:)`, look up a persisted zoom level
  for the registrable domain (`registrableDomain(from:)` in `Core/Utilities/Utils.swift`
  already gives you the right key), apply via `page.zoom`. Cmd+=/-/0 update and persist.
  Store levels in a `[String: Double]` settings blob like `sitePermissions`.
- **Permissions UX**: media capture currently hard-codes `.prompt`
  (`TabBrowserPageDelegate.requestPermission`) which shows WebKit's raw dialog. Build a
  native permission sheet matching the password-save prompt pattern
  (`PasswordAutofillCoordinator.presentSavePrompt`), with Remember / Allow once / Deny,
  persisted into the existing `SitePermissionSettings` map, plus a management list in
  Settings → Privacy next to the JS rules.
- **Site info panel**: click the lock/host in the URL pill → popover showing origin,
  JS policy toggle (`JavaScriptPolicyService.setRule`), camera/mic/location grants, zoom,
  cookies cleared-for-site (`PrivacyService.clearAllData(forHost:)`), and the space rule
  if one exists (`SiteSpaceRuleService.containerID(for:)`). One place answering "what is
  this page allowed to do" is what users actually poke when they distrust a site.

## 4. Extension support: from working demo to daily-driver

Extensions load and run today — consent gate, toolbar buttons, popups, the blocking
`webRequest` bridge, tab/window adapters. What is missing is the layer of correctness
that makes people trust them with their browsing:

- **Private windows**: extensions are hard-disabled there (`attach(to:)` guards
  `!isPrivate`; `currentTabAdapter` returns nil). Firefox's model is the right target:
  the extension runs in private windows but *sees no private tabs* unless granted.
  Attach the controller to private configurations too, keep `ExtensionTabAdapter`
  creation gated on a new per-extension "run in private windows" grant (default off,
  surfaced as a toggle next to the consent sheet), and make `tabs.query`/adapters skip
  private tabs for un-granted extensions. Never let the shim or bundle treat a private
  store differently from what it already does — the data-store split is already correct.
- **webRequest surface beyond `onBeforeRequest`**: the broker's `Listener.matches`
  accepts only that event. Add `onBeforeSendHeaders`/`onHeadersReceived` verdicts to the
  shim protocol (the bundle reads headers off the bridged NSURLRequest already; replies
  would carry a header patch set). Be honest about the ceiling here:
  `WKURLRequest` exposes no header-writing API, so request-header *modification* may be
  impossible through this C API — if so, support response-header handling at the
  extension layer via WebKit's native hooks where available, and document the limit in
  `ExtensionCompatibility` notes rather than silently misbehaving. Blocking and
  redirecting (the uBlock-critical paths) must stay exact.
- **Extension updates**: an installed add-on never updates today. Add a version check
  against AMO for gecko-id'd extensions (`FirefoxAddonStore`), surface "Update available"
  in Settings → Extensions, and update = re-download `.xpi`, unpack over the same
  directory id, re-run the shim patch. The consent machinery already handles the risky
  case: a changed permission set re-prompts via the hash comparison. Preserve
  `aura-shim-manifest.js` regeneration and storage continuity (stable
  `uniqueIdentifier`).
- **i18n manifests**: `parseManifest` bails on `__MSG_*__` names and falls back to the
  folder id, which is what the UI then shows. Resolve against `_locales/<lang>/messages.json`
  (default locale first, then `navigator.language`) at registration time.
- **Error surfacing**: `loadIntoEngine` sleeps three seconds and reads
  `context.errors` once. Replace with polling until the context reports it finished
  launching (or errors arrive), and render runtime errors in the Settings row live
  instead of a one-shot snapshot.
- **Commands API**: map `_execute_action` and declared commands into
  `CustomKeyboardShortcutManager` ids so users can bind extension actions like any other
  shortcut; fire `commands.onCommand` through the engine.
- **Uninstall hygiene**: `removeExtension` deletes the directory and unloads, but leaves
  the consent record, and never purges the extension's own storage/data records keyed by
  its `uniqueIdentifier`. Purge both.

Acceptance: uBlock blocks in a private window after granting, an installed extension
updates without losing settings, a renamed-localized add-on shows its real name, and
removing an extension leaves zero traces behind.

For the bundled ad blocker specifically — including how full uBlock Origin returns
alongside uBlock Origin Lite — see `UBLOCK-ORIGIN.md`.

## 5. Downloads hardening

The pipeline works but is thin for daily traffic:

- Progress badge on the toolbar/downloads widget with aggregate speed and ETA
  (`Download.progress` is already tracked at 10 Hz).
- Concurrent-download cap (2–3) with queueing; today they all run at once.
- "Downloads window" polish: reveal-after-quarantine hint for `com.apple.quarantine`
  stamped files, and double-click behaviour consistent with `openIfSafe`'s safe-types
  list (`DownloadDestination.safeExtensions`).
- Ask-where-to-save should pre-resolve collisions and offer "Keep both / Replace /
  Cancel" instead of silently uniquifying (`createUniqueFilename`).

## 6. Web-content UX completeness

Context menu (`PageContextMenu.swift`) has Print — add the rest of the daily set:
Open Image in New Tab, Save Image/Copy Image (`webView.createPDF` is wrong here; use
`WKWebView.takeSnapshot` for images? No — use the `contextMenu` bridge script's image
URL and fetch via URLSession, honoring the page's own referrer), Search Selection With
(default engine), Copy Link With Clean Parameters (strip `utm_*`), and Reopen In Space
(uses `moveTabToContainer`).

Add: View Source (load `view-source:` equivalent by fetching the HTML into a
data-url tab), Reader Mode (extract article text with the already-bundled SwiftSoup and
render natively — same trick as aura:// pages), Save Page As (single-file HTML +
resources via `createWebArchiveData`), and full-page screenshot to file
(`takeSnapshot` with document rect).

Drag-and-drop: dropping a URL/text selection onto the web content area or sidebar
should navigate/open-in-new-tab; dragging a tab out to Finder should drop its URL.
`TabDragSession` already handles intra-app drags — extend its pasteboard writer.

## 7. Opening local files and PDF previews

A browser people live in gets handed local files constantly. Aura currently has no
answer: `constructURL(from:)` in `Core/Utilities/Utils.swift` only ever produces
http/https URLs, so typing a path searches the web instead of opening the file.

- **Getting files in**: ⌘O opens an `NSOpenPanel`; dropping a file onto the window,
  the dock icon, or the sidebar navigates a new tab to its `file://` URL;
  `AppDelegate.handleIncomingURLs` already receives open-file events — route file URLs
  through it (register document types in `project.yml`: pdf, html, htm, txt, md, images).
  Extend `constructURL` to recognise absolute POSIX paths, `~/…`, and existing
  `file://` strings before falling back to search.
- **Sandbox access**: if the app is sandboxed, a path typed into the address bar is one
  the sandbox has no right to read. Open-panel and drag-drop origins carry implicit
  grants; typed paths need an explicit consent prompt ("Aura wants to open this file")
  that then persists a security-scoped bookmark per file. The pattern exists twice
  already (`SecurityScopedFolder`, `downloadFolderBookmark`) — build a small
  `FileAccessStore` on top of it keyed by path.
- **PDF preview**: WebKit renders PDFs inline on modern macOS, and
  `BrowserPage.decidePolicyFor(navigationResponse:)` already allows displayable types —
  verify remote *and* `file://` PDFs land in the inline viewer rather than the download
  path (the Content-Disposition attachment check must keep winning where a site really
  does want a download). Make sure zoom controls and find-in-page work against WebKit's
  PDF view; if they do not, fall back to a native PDFKit page rendered like aura://
  pages rather than shipping a half-working viewer.
- **The file tray**: a sidebar widget next to `DownloadsWidget` listing every file
  opened this session, persisted across launches so yesterday's chapter is one click
  away. Each row's subtitle shows the exact percent-encoded location, e.g.
  `file:///Users/aniko/Documents/Subjects/Patrick/Year%209/Chapter-4-Worked-Solutions.pdf`
  — copyable verbatim, since users paste these paths into other tools. Clicking a row
  reopens the file in a tab; closing its tab removes the entry unless pinned to the
  tray. Row actions: Reveal in Finder, Open in Default App, Copy Path, Remove. Store
  entries as a SwiftData entity alongside bookmarks (V-next migration) so they survive
  restarts and sync with session restore.
- **Non-PDF files**: images and text/code render inline via WebKit as today; anything
  WebKit cannot display follows the normal download flow instead of showing a blank tab.

## 8. Keyboard and navigation polish

- Back/forward long-press history menu: right-click (or long-press) on the nav buttons
  shows the session's back/forward entries using the persisted stacks from workstream 2.
- Hard reload (⇧⌘R): `reload()` ignoring cache — set
  `URLRequest.cachePolicy = .reloadIgnoringLocalCacheData` via a re-load of current URL.
- Full keyboard access: ensure every toolbar button, sidebar row, and menu item has an
  accessibility label and appears in full-keyboard-access order; run Accessibility
  Inspector over the chrome once and fix what it flags.
- Command palette stretch goal: the launcher (`LauncherViewModel`) already scores and
  merges sources; adding a `command://` source (all `OraCommands` items) turns it into a
  Raycast-style palette nearly for free.

## 9. Data portability

- Extend `Importer` (it reads Arc's sidebar format) to import bookmarks from Chrome,
  Firefox, Edge, and Safari (HTML bookmark export format covers three of the four;
  Safari needs `~/Library/Safari/Bookmarks.plist` via NSKeyedUnarchiver).
- Export: bookmarks to HTML (universal), passwords to CSV *behind* an auth prompt and
  loud warning (industry-standard escape hatch; use `revealPassword` which authenticates),
  and a full-settings export/import via `UserDefaults` dictionary diff (respecting the
  `isSystemKey` exclusions from `LegacyDataMigrator`).
- Default-browser onboarding: `DefaultBrowserManager` exists — surface a first-run card
  that offers to set Aura default and imports on first launch, dismissible forever.

## 10. Quality gates for everything above

Each workstream ships with:

1. Unit tests in `auraTests/` following the existing pure-logic style — bookmark store
   CRUD, zoom persistence keyed by eTLD+1, consent-free migration V3→V4 on a fixture,
   importer parsers against fixture files committed under `auraTests/Fixtures/`.
2. No new force-unwraps, `saveOrLog` for every SwiftData write, doc comments explaining
   *why* on anything non-obvious — match the house style visible in
   `WebRequestBroker.swift` and `ContainerManager.swift`.
3. Schema changes go through a new `AuraSchemaV(N)` + explicit stage; never mutate an
   existing versioned schema.
4. Anything touching the injected bundle's wire protocol (message names, JSON shape)
   must stay byte-compatible with `auraWebBundle/` on both ends in the same changeset.
   New message names or fields are sanctioned only where this plan says so: the startup
   probe (`AUDIT-DEEP-ISSUES.md` item 7) and the header-verdict extension of workstream 4.
   Never ship a Swift-side change to the protocol without the matching ObjC change.

## Sequencing and scope discipline

Workstreams 1–3 are the daily-driver core: do them completely before anything else.
A user can forgive a missing reader mode; nobody forgives no bookmarks, lost back
history, and un-zoomable text. Workstream 4 (extensions) sits just behind them because
the people who would switch to Aura are exactly the ones who will not browse without
uBlock — its private-window gap and update story are the first trust-breakers they hit.
Workstreams 5–8 are polish that makes the difference between "usable" and "pleasant";
9 removes the last switching excuse; skip sync entirely — it is a product decision, not
a coding task, and doing it badly is worse than not shipping it.

When a workstream forces an architectural choice not covered here (bookmark storage
shape, permission-prompt presentation), prefer consistency with existing patterns over
novelty: this codebase's strength is that every subsystem looks like the last one.
Write down any deviation in the PR description, not just the code.
