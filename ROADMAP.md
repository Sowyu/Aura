# Aura roadmap

Aura is in active development. This page shows the direction, not an exhaustive issue
tracker. The feature list in [README.md](README.md) is the source of truth for what
already works.

## Latest release

v1.2.3 is the latest tagged release. It includes:

- Spaces, containers, vertical tabs with folders and pinning, a launcher, rebindable
  shortcuts
- Bookmarks and reading list with import from other browsers, history, downloads with
  a queue, session restore with crash recovery
- Web extensions from addons.mozilla.org, bundled uBlock Origin Lite, opt-in full
  uBlock Origin
- Password vault with Keychain autofill, per-site zoom and JavaScript rules, native
  camera and microphone prompts
- Reader mode, view source, web archives, full-page screenshots, local files and
  inline PDFs
- Signed DMG releases with in-app automatic updates

## Current development branch

The September polish work passed
[macOS CI](https://github.com/Sowyu/Aura/actions/runs/34173768812) and has not been
released. It adds responsive launcher and address-bar focus, compact-mode ⌘L
behavior, native Print with ⌘P, a stop-loading control, per-site zoom commands, and
system Reduce Motion support. It also completes Aura naming across app types and shared controls.

## Near term

- Notarized releases, so the first launch no longer needs right-click and Open
- Performance on the hot paths: the cost of opening a tab when the app is warm, and
  sidebar rendering in spaces with many tabs
- Full uBlock Origin reliability: automatic paint-health checks for the compatibility
  mode it requires, and groundwork for request-level blocking that does not need that
  mode at all
- Web notifications
- Passkeys

## Longer term

- Split view and preview-style browsing workflows
- More personalization and interface polish
- Stability hardening across multi-window data handling and the extension bridge

## Feedback

Open an issue to discuss priorities or propose a feature. For the contribution
workflow, see [CONTRIBUTING.md](CONTRIBUTING.md).

_Last updated: September 2026_
