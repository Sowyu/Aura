# Code audit, September 2026

Status: the earlier security pass passed macOS CI. The 8 September polish pass is undergoing native regression checks.
Baseline commit: `73f9b86`. Changes are committed on `audit/native-validation-20260907`.
No release or deployment was made.

## Polish pass, 8 September

The retained review contains 273 entries, including duplicate reports of the same
issue. All 268 routed entries now have implementation changes. The remaining five
cover the Aura rename and documentation. [polish/progress.json](polish/progress.json)
tracks implementation status separately from validation. The original evidence and
suggested fixes remain in [polish/packages.json](polish/packages.json).

The pass fixes address and launcher focus, window-scoped commands, tab ordering and
restore, download feedback, extension update failures and messaging cleanup. Dialogs
and sidebar panels use shared controls, destructive actions ask for confirmation,
and animation helpers respect the macOS Reduce Motion setting. Native accessibility
labels and actions cover rows, pickers and transport buttons.

Chrome types, internal URL helpers, injected script globals and logo assets now use
Aura names. `OraData.sqlite`, the legacy migration code, frozen SwiftData schemas and
the readable `ora://` URL alias retain their compatibility identities.

Location requests use the public macOS 27
[WebKit delegate](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:requestgeolocationpermissionfor:initiatedbyframe:decisionhandler:)).
The explicit Objective-C selector also builds with the Xcode 26 CI SDK. Runtime
location prompting still needs a macOS 27 check.

The 13 portable bridge tests pass. macOS CI built the renamed application, passed
the Release launch check and all 27 gated WebKit tests. Four hibernation fixture
failures in the 681-test suite have corrections queued for a final run.
No manual VoiceOver, populated-profile UI review, notarization or release is claimed.

## Earlier security and startup validation

The subsequent startup cleanup is validated at `05a12f9` in
[run 34109366660](https://github.com/Sowyu/Aura/actions/runs/34109366660).
Debug and Release builds, formatting, lint, the native suite, injected WebKit checks
and the Release launch UI test passed. It also removes a tab-manager retain cycle
and verifies manager deallocation. [PERFORMANCE.md](PERFORMANCE.md) records the
launch samples and their limits; [CONTRIBUTING.md](CONTRIBUTING.md) covers setup,
code locations and the commands to repeat the checks.

The subsequent [performance pass](PERFORMANCE.md) records reduced bridge work and
native changes awaiting profiling. The portable suite now contains ten tests.
The macOS runs caught a generic static-property compile error, formatting failures,
test window ownership errors and use of WebKit's callback overload where the test
needed its async result. Those fixes are included on the branch.

The largest problems were trust boundaries and lifecycle handling. Page JavaScript
could influence trusted browser state, optional extension permissions were granted
without a decision, and private data reached shared storage paths. Cosmetic cleanup
alone would have left those bugs intact.

## Coverage and limits

The inventory contains 316 application source files and 63 Swift test files, plus
the Objective-C injected bundle and build tooling. This pass combined repository-wide
static searches with focused reads of callers, delegates, persistence and bridge
implementations. It was not an exhaustive manual reading of every source line.

| Area | Reviewed | Verification still needed |
| --- | --- | --- |
| Security | Password bridge, trusted navigation state, camera/microphone grants, extension permissions, request broker, archive and download entry points | Autofill during navigation and authentication, permission revocation, malicious archive fixtures |
| Privacy | Private profiles, extension visibility, source captures, suggestions, favicons, session/history guards | Inspect on-disk artifacts after private browsing and quitting |
| Correctness | Async tab/page ownership, callback completion, file grants, settings imports, persistence error paths | SwiftData failures, Keychain authentication, native dialogs |
| Architecture and tooling | Duplicate origin logic, dead flags/types, cache keys, port ownership, dependencies, CI and release scripts | Reproducible dependency resolution and vulnerability review |
| Interface | Sidebar accessibility actions and motion helpers, reviewed in source | VoiceOver, keyboard navigation, system Reduce Motion, visual and performance checks in the running app |

This Debian environment has no Swift compiler, Xcode or macOS frameworks. Native
validation runs on GitHub's Apple Silicon macOS runner with Xcode 26.0.1. Syntax
parsing alone cannot establish Swift type correctness or native runtime behavior.
No visual quality score or whole-browser CPU or memory measurement is claimed.

## Security and privacy fixes

| Priority | Finding and change | Main files |
| --- | --- | --- |
| High | The password bridge and handler shared the website's JavaScript world. They now use an isolated content world. Native messages must originate in that world, in the main frame, at the current web origin. | [BrowserPage.swift](aura/Core/BrowserEngine/BrowserPage.swift), [AuraBrowserScripts.swift](aura/Core/BrowserEngine/Scripts/AuraBrowserScripts.swift) |
| High | Authentication could finish after navigation and fill a different document. Each document now creates a random ID. Fill requests must carry it, and the native coordinator rechecks the page, origin, focus, provider and privacy settings after authentication. Synthetic keyboard events cannot activate autofill. | [PasswordAutofillCoordinator.swift](aura/Features/Passwords/Services/PasswordAutofillCoordinator.swift), [password-manager.js](aura/Resources/WebScripts/password-manager.js) |
| High | A forged `listener` message could supply the displayed address and history URL. The delegate now reads URL and title from its current BrowserPage; the message only triggers a refresh. | [TabBrowserPageDelegate.swift](aura/Features/Tabs/Browser/TabBrowserPageDelegate.swift) |
| High | A camera/microphone decision covered the registrable domain and its subdomains. Grants now distinguish scheme, host and port. Cancelled prompts cannot later write a grant. Old domain-only grants prompt again because their original origin was never stored. | [SettingsStore+Collections.swift](aura/Core/Utilities/SettingsStore+Collections.swift), [SitePermissionCoordinator.swift](aura/Features/Browser/Permissions/SitePermissionCoordinator.swift) |
| High | Runtime extension requests automatically received every requested permission and host. Requests now show an explicit Allow/Don't Allow sheet and fail closed without a suitable window. Private window enumeration, extension tabs and extension page hosting respect the context's private access. | [ExtensionControllerDelegate.swift](aura/Features/Extensions/Services/ExtensionControllerDelegate.swift), [ExtensionManager.swift](aura/Features/Extensions/Services/ExtensionManager.swift) |
| High | The custom request broker bypassed host grants and could forward private traffic to extensions. It now checks the loaded context's webRequest and URL access. Private pages use WebKit's native extension path because the custom IPC does not identify private requests. Replies only count from extensions asked about that request. | [WebRequestBroker.swift](aura/Features/Extensions/Services/WebRequestBroker.swift), [BrowserPage.swift](aura/Core/BrowserEngine/BrowserPage.swift) |
| High | Source captures were shared by URL, allowing a second tab or container to reuse private/authenticated HTML. Captures now belong to the destination tool tab and clear when it closes. Capture completion checks that the source page still owns the tab and URL. | [PageSourceStore.swift](aura/Features/PageTools/PageSourceStore.swift), [PageTools.swift](aura/Features/PageTools/PageTools.swift) |
| High | The extension shim followed a manifest's HTML path outside its directory. HTML reads and writes now check containment after path normalization and symlink resolution. This does not certify archive extraction itself. | [ExtensionShim.swift](aura/Features/Extensions/Services/ExtensionShim.swift) |
| Medium | Private launcher suggestions used a shared persistent URLSession, and private tab favicons were downloaded to disk. Suggestions now use an ephemeral session without cookies or a URL cache. Private tabs use the default icon until favicon downloads support an in-memory path. | [SearchEngineService.swift](aura/Features/Search/Services/SearchEngineService.swift), [Tab.swift](aura/Features/Tabs/Models/Tab.swift) |

The isolation approach follows Apple's [WKContentWorld documentation](https://developer.apple.com/documentation/webkit/wkcontentworld).
Content worlds isolate JavaScript globals, while the DOM remains shared. The document
ID check is therefore needed in addition to the native origin check.

Permission scoping follows the origin-based key described in the
[Permissions specification](https://w3c.github.io/permissions/#permission-key).
The extension API checks were compared with WebKit's
[context header](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebExtensionContext.h).

## Correctness and maintenance fixes

- Removed the injected bundle's request verdict cache. Its URL/type/document key
  omitted method, headers and extension state. Reusing a decision could bypass
  changed filtering rules. Every request now gets a fresh decision; the existing
  timeout and backpressure limits remain. Measure the IPC cost on macOS.
- Fixed port callback ownership so old disconnects cannot detach replacement ports,
  and callbacks do not retain their own ports. Listener keys now preserve the full
  extension ID and listener ID instead of storing only their hash.
- Settings imports validate the complete document before writing defaults. Wrong
  app/version, malformed values, duplicate keys and invalid base64 fail before any
  preference changes. Machine-specific file-access bookmarks are excluded. Password
  saves retain whitespace, preserve the originating container and report save errors.
- Security-scoped file access now starts before it is reported as open and stops
  when forgotten or pruned. JavaScript confirm/prompt and file picker callbacks
  complete even without a delegate. Add-on listing URLs require the exact HTTPS host,
  downloads reject failed HTTP responses, and archive extraction drains stderr while
  the child process runs to avoid a full-pipe deadlock.
- Added sidebar accessibility actions and synchronized the motion preference cache.
  CI now runs portable bridge checks, hashes actual SPM inputs and uses cache v4.
  SwiftSoup is declared directly because application code imports it. Build/release
  cleanup uses recoverable Trash; setup and CI install the required tool. Release
  tagging occurs after artifact construction and signing.

The small complexity cuts, with current file locations:

`aura/Core/BrowserEngine/BrowserEngine.swift:L49: shrink: a cache key carried an always-false private flag. Use UUID directly.`

`aura/Features/Tabs/Models/Tab.swift:L14: delete: URLUpdate existed to decode untrusted address-bar state. Read BrowserPage instead.`

`aura/Shared/Components/Buttons/OraButton.swift:L22: delete: isLoading had no behavior or callers.`

`aura/Features/Extensions/Services/ExtensionManager.swift:L192: yagni: attach accepted an unused private flag for a hypothetical future decision. Remove that argument.`

net: -15 lines, -0 dependencies in those four cuts. The overall patch adds validation
and regression coverage; reducing total line count was not the acceptance criterion.

## Checks performed

1. `bash scripts/check-local.sh` passes. It checks shell syntax, parses shipped page
   scripts, runs ten dependency-free Node tests against the shipped bridge scripts,
   and runs `git diff --check`.
2. All four bridge regressions fail against the original script from `73f9b86`.
   They cover document replacement, missing document IDs, synthetic Enter events and
   submission metadata. The current script passes all four.
3. Tree-sitter Swift parsing found no additional syntax errors in the changed/new
   Swift files relative to the baseline. The project, CI, lint and hook YAML files
   parse. This is not a compiler or formatter check.
4. The Trash helper was exercised on disposable files, including spaces, an absent
   path, a symlink and an invalid relative path. The symlink target survived. Test
   fixtures were moved to Trash.
5. Added or extended native tests for content-world isolation, origin-scoped
   permissions, stale permission answers, private capture/favicons, import validation,
   extension resource boundaries, file grants, motion synchronization and bridge
   encoding. The macOS CI suite now executes these checks.

## macOS CI results

[Run 34097390651](https://github.com/Sowyu/Aura/actions/runs/34097390651) validates
code commit `341294a72b58b4313079f225a585e77cedaadb53` on Apple Silicon with Xcode 26.0.1.
Documentation updates after that commit do not change the tested code.

- Debug compilation passes. The two XCTest cases pass, and Swift Testing reports a
  passing 656-test suite with 17 opt-in tests skipped in the default run.
- The separate integration run passes 26 tests, including all 14 opt-in WebKit and
  popup checks. The three long performance benchmarks remain disabled.
- The password test verifies that website JavaScript cannot replace the isolated
  bridge or access its message handler. Extension tests exercise cancellation,
  redirects, resource types, unloading, timeouts, messaging and popup rendering.
- Fifty extension page opens finish with zero retained tunnelled ports. This is a
  relay ownership check, not a whole-process memory measurement.
- Release compilation, SwiftFormat and SwiftLint pass. SwiftLint reports 156
  warnings and zero serious violations; a successful exit does not mean the
  repository is warning-free.

The test window fixes follow Apple's [ARC ownership requirement](https://developer.apple.com/documentation/appkit/nswindow/isreleasedwhenclosed).
The password test now awaits the [content-world evaluation overload](https://developer.apple.com/documentation/webkit/wkwebview/evaluatejavascript(_:in:contentworld:)).
The callback overload returns `Void`; awaiting it did not return JavaScript's value.

CI disables code signing. These checks do not validate notarization, signed sandbox
behavior, biometric prompts, VoiceOver or whole-browser CPU and memory use.

## Open findings

These are remaining work, not claims that the affected paths are safe.

| Priority | Finding | Required follow-up |
| --- | --- | --- |
| Release gate | Automated macOS checks pass; signed-app and manual platform checks remain. | Verify notarization, signed sandbox behavior, authentication during navigation, permission revocation and private data on disk before release. |
| High | [XPIUnpacker](aura/Features/Extensions/Services/FirefoxAddonStore.swift) delegates extraction to ditto without application-level entry/size limits. Local CRX signatures are explicitly not verified. | Test traversal, symlinks and oversized archives on macOS; define and enforce the supported trust and size limits. Do not treat HTTPS status checks as signature verification. |
| Medium | [BookmarkPortability.apply](aura/Features/Importer/Services/BookmarkPortability.swift) returns an added-count summary after `saveOrLog`, even if saving failed. [HistoryManager](aura/Features/History/Services/HistoryManager.swift) also discards some save errors. | Add persistence failure tests and propagate save failures without rolling back unrelated edits in the shared context. |
| Medium | [ExtensionVersion](aura/Features/Extensions/Services/ExtensionUpdates.swift) compares suffixes lexically. For example, `1.0` is not considered newer than `1.0b2`. | Adopt the supported Firefox version ordering and test prerelease-to-release updates. |
| Medium | [ReaderView](aura/Features/PageTools/ReaderView.swift) still loads article images through AsyncImage. Private native image requests have not been proven free of persistent caching. | Give private native image loading an explicit ephemeral policy and inspect disk writes during an integration test. |
| Medium | [SettingsBackup](aura/Features/Importer/Services/SettingsBackup.swift) validates property-list compatibility, but not every preference's expected type or allowed range. | Add a preference schema or reject unknown/type-mismatched settings at import. |
| Medium | The custom blocker relies on private WebKit interfaces and synchronous waits. Removing its invalid cache can increase work. | Exercise the injected bundle tests and measure navigation latency, hangs and extension timeout behavior. |
| Medium | `Package.resolved` is ignored; several dependencies use minimum-version constraints. Lint tools are also installed without a pinned version. | Produce and retain a reproducible dependency resolution, pin CI tooling, and perform a vulnerability review of the resolved versions. |
| Accessibility | System Reduce Motion now feeds AnimationSettings. No running-app VoiceOver audit was possible. | Test the native controls with VoiceOver, keyboard input and system accessibility settings. |

Behavior changes to review: old camera/microphone grants ask again, additional
extension access needs consent, private tabs use default favicons, and full uBlock
Origin's custom request blocking does not run in private windows. WebKit's native
extension filtering remains available subject to private-access grants.

On macOS with the setup dependencies installed:

```bash
xcodegen
swiftformat --lint .
swiftlint lint
bash scripts/xctest-debug.sh
```

Then run the opt-in injected-bundle tests:

```bash
TEST_RUNNER_AURA_BUNDLE=1 bash scripts/xctest-debug.sh
```

Also exercise password authentication while navigating, repeated extension popup
opens, permission revocation, private browsing and bookmark-save failures. A passing
portable suite alone does not satisfy those release checks.
