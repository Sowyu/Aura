# Contributing to Aura

## Run the app

Use a Mac with macOS 15 or later, Xcode 26 and Homebrew. CI pins Xcode 26.0
and records the resolved version. Web extensions need macOS 15.4 or later.

```bash
git clone https://github.com/Sowyu/Aura.git
cd Aura
bash scripts/setup.sh
open Aura.xcodeproj
```

Choose the `aura` scheme and run. Local signed builds need your development team
selected in Xcode. The validation commands below build without signing.

Edit `project.yml` when changing targets, dependencies or build settings, then run
`xcodegen`. The generated Xcode project is not the source of configuration.

## Find the code

| Change | Start here |
| --- | --- |
| Launch, windows and command routing | `aura/App/AuraApp.swift`, `aura/App/AuraRoot.swift` |
| Tabs, spaces and session restoration | `aura/Features/Tabs/State/`, `aura/Features/Tabs/Models/` |
| Page loading and native WebKit callbacks | `aura/Core/BrowserEngine/` |
| Extension APIs and injected request handling | `aura/Features/Extensions/`, `auraWebBundle/` |
| Website scripts and their portable tests | `aura/Resources/WebScripts/`, `scripts/*-bridge.test.cjs` |

Other features live under `aura/Features/`. Native regression tests live in
`auraTests/`. The `AuraLaunch` scheme runs the Release UI launch test in
`auraUITests/auraUITestsLaunchTests.swift`.

Trace callers before changing a shared function. Reuse existing helpers and native
APIs before adding dependencies or abstractions. Keep private browsing state out of
shared persistent stores. Use `AuraLog` for diagnostics and availability checks for
APIs newer than the deployment target.

## Check a change

On Linux or macOS with Node 22 or later:

```bash
bash scripts/check-local.sh
```

This checks shell and website-script syntax, runs the bridge regression tests and
checks patch whitespace. It cannot compile Swift or validate WebKit behavior.

On macOS, after setup:

```bash
swiftformat --lint .
swiftlint lint
bash scripts/xctest-debug.sh
```

The native script builds the Debug test host and runs the unit suite. To check the
injected WebKit path, use the same DerivedData directory from that build:

```bash
TEST_RUNNER_AURA_BUNDLE=1 xcodebuild test-without-building \
  -project Aura.xcodeproj -scheme aura -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA:-/tmp/dd-aura-prepush}" \
  -only-testing:auraTests/WebBundleTests \
  -only-testing:auraTests/WebRequestBrokerTests \
  -only-testing:auraTests/BrowserPageTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=
```

Measure launch with a Release build:

```bash
xcodebuild test -project Aura.xcodeproj -scheme AuraLaunch \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/dd-aura-launch \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=
```

The launch test opens and terminates Aura repeatedly. Run it with your normal Aura
session closed, preferably in a separate macOS user account. It uses that account's
browser profile. See [PERFORMANCE.md](PERFORMANCE.md) for measurement limits.

Setup installs Lefthook. Pre-commit formats and lints staged Swift files; pre-push
checks documentation policy and runs the Debug build and unit tests. Run
`swiftformat .` to apply formatting before committing.

## Submit a change

Keep the diff focused and leave a regression check for changed behavior. A pull
request should explain the problem, resulting behavior and validation performed.
Include screenshots for visible UI changes. Performance claims need the workload,
build configuration, hardware and before/after measurements. Lower memory use is
not a win if it drops features, loses data or makes interaction slower.

Contributors are responsible for understanding and checking their submissions.
Never commit secrets or signing keys. See [SECURITY.md](SECURITY.md) for reporting
vulnerabilities and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for conduct standards.
