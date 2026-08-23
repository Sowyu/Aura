<div align="center">
  <img width="150" height="150" src="/assets/icon.png" alt="Aura Browser logo">
  <h1>Aura Browser</h1>
  <p>Fast, native WebKit browser for macOS.</p>
  <a href="https://vercel.com/oss">
  <img alt="Vercel OSS Program" src="https://vercel.com/oss/program-badge.svg" />
</a>
</div>
<br/>
<p align="center">
  <a href="https://www.apple.com/macos/"><img src="https://badgen.net/badge/macOS/15+/blue" alt="macOS 15+"></a>
  <a href="https://developer.apple.com/xcode/"><img src="https://badgen.net/badge/Xcode/15+/blue" alt="Xcode 15+"></a>
  <a href="https://swift.org"><img src="https://badgen.net/badge/Swift/5.9/orange" alt="Swift 5.9"></a>
  <a href="https://brew.sh"><img src="https://badgen.net/badge/Homebrew/used/yellow" alt="Homebrew"></a>
  <a href="LICENSE"><img src="https://badgen.net/badge/License/GPL-3.0/green" alt="GPL-3.0"></a>
</p>


## Overview

Aura is a macOS browser built with SwiftUI, AppKit, and WebKit. The project aims for a native, low-friction browsing experience without layering on unnecessary product surface area.

## Highlights

- Native macOS UI
- WebKit-based browsing
- Built-in content blocking and privacy protections
- Search engine customization
- URL suggestions and quick launcher
- Developer-focused features

## Install

Download `Aura-<version>.dmg` from the [latest release](https://github.com/Sowyu/Aura/releases/latest), open it and drag Aura to Applications. The app is signed but not notarized, so the first launch needs a right-click on Aura.app and Open.

Aura checks for updates at launch and every six hours. When a new release is out, an "Update to x.y.z" button appears in the toolbar and under Settings, About; one click downloads, installs and relaunches.

## Quick Start

```bash
git clone https://github.com/Sowyu/Aura.git
cd Aura
./scripts/setup.sh
open Aura.xcodeproj
```

The setup script installs required tooling, installs git hooks, and regenerates the Xcode project.

## Development

- Main app target: `aura`
- Project configuration is managed with `XcodeGen` in `project.yml`
- Regenerate the project after config changes with `xcodegen`
- Run tests in Xcode with `Product > Test` or via `xcodebuild test -scheme aura -destination "platform=macOS"`

## Docs

- [Contributing](CONTRIBUTING.md)
- [Roadmap](ROADMAP.md)
- [Security](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## Links

- [Website](https://www.orabrowser.com)
- [Discord](https://discord.gg/9aZWH52Zjm)
- [GitHub Sponsors](https://github.com/sponsors/the-ora)
- [Buy Me a Coffee](https://buymeacoffee.com/orabrowser)
- [X / Twitter](https://x.com/orabrowser)

## License

Aura Browser is licensed under [GPL-3.0](LICENSE). Third-party libraries used by this project are licensed under their own open-source licenses.
