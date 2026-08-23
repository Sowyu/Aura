import CoreGraphics
import Foundation
import Testing

@testable import Aura

/// The opt-in full uBlock Origin: the blob Aura vendors, and the rule that decides
/// which of the two blockers a launch runs.
///
/// Everything here is pure or reads a file. The one part these cannot cover is whether
/// an offscreen probe window reproduces the layer purge on a given macOS build, which
/// is verified by hand per OS beta; see `AuraWebBundle.PaintProbe`.
struct FullUBlockOriginTests {
    private typealias Pin = BundledExtensions.FullUBlockOrigin

    // MARK: - The vendored archive

    /// The archive in the app bundle is the release the pin names. Shipping GPL-3.0
    /// binaries means the tag in the notices has to be the source of this exact file,
    /// and an extension asking for `<all_urls>` is not something to install off a blob
    /// nobody checked.
    @Test func vendoredArchiveMatchesThePinnedHash() throws {
        let url = try #require(Pin.archiveURL, "ublock-origin.xpi is missing from the app bundle")
        let data = try Data(contentsOf: url)
        #expect(Pin.sha256(data) == Pin.archiveSHA256)
        #expect(Pin.verifiedArchiveURL() != nil, "the install path refuses an archive that fails the hash")
    }

    /// The pin, the asset name and the source offer all name one release.
    @Test func pinnedVersionIsSpelledTheSameEverywhere() {
        #expect(Pin.assetName == "uBlock0_\(Pin.version).firefox.signed.xpi")
        #expect(Pin.releaseURL.hasSuffix("/releases/tag/\(Pin.version)"))
        #expect(Pin.archiveSHA256.count == 64)
    }

    /// GPL-3.0: the ledger carries the component, its licence and the tag the binary
    /// was built from. The About section renders this file, so it ships with the app.
    @Test func thirdPartyNoticesRecordTheRelease() throws {
        let url = try #require(
            Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
            "the notices are rendered by the About section and have to be in the bundle"
        )
        let notices = try String(contentsOf: url, encoding: .utf8)
        #expect(notices.contains("## uBlock Origin\n"))
        #expect(notices.contains(Pin.archiveSHA256))
        #expect(notices.contains(Pin.releaseURL))
        #expect(notices.contains("aura/Resources/Extensions/LICENSE-ublock-origin.txt"))
        #expect(notices.contains("GPL-3.0"))
    }

    /// The archive unpacks to what the pin says it is, and lands somewhere the install
    /// path can read a manifest from.
    @Test func archiveUnpacksToThePinnedVersion() throws {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-ubo-full-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }

        let folder = try #require(BundledExtensions.unpackFullIfNeeded(into: profile))
        #expect(folder.lastPathComponent == Pin.folderName)

        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        ) as? [String: Any]
        #expect(manifest?["version"] as? String == Pin.version)
        let settings = manifest?["browser_specific_settings"] as? [String: Any]
        #expect((settings?["gecko"] as? [String: Any])?["id"] as? String == Pin.geckoID)

        // Second call finds the folder and leaves it exactly as it is: a copy that has
        // been running must never be overwritten underneath the user.
        #expect(BundledExtensions.unpackFullIfNeeded(into: profile)?.path == folder.path)
    }

    /// Full uBO is not the pre-consented one. Installing Aura is consent for what Aura
    /// puts in the profile by itself, and this is not that: it asks for `<all_urls>`
    /// and changes how every page is rendered.
    @Test func fullUBlockOriginIsNotPreConsented() {
        #expect(!BundledExtensions.isBundled(id: Pin.folderName, geckoID: Pin.geckoID))
        #expect(!BundledExtensions.preConsentedIDs.contains(Pin.folderName))
        #expect(!BundledExtensions.preConsentedIDs.contains(Pin.geckoID))

        let request = ExtensionConsentRequest(
            id: Pin.folderName,
            displayName: "uBlock Origin",
            displayDescription: nil,
            version: Pin.version,
            source: .archive(Pin.assetName),
            permissions: ["webRequest", "webRequestBlocking", "<all_urls>"]
        )
        #expect(ExtensionConsent.decision(for: request, stored: nil) == .prompt)
    }

    /// The folder full uBO installs into is not the one the old preinstall used, which
    /// `installIfNeeded` deletes on sight when Aura is the one that put it there.
    @Test func theInstallFolderDoesNotCollideWithTheOldPreinstall() {
        #expect(Pin.folderName != BundledExtensions.legacyFolderName)
        #expect(Pin.folderName != BundledExtensions.folderID)
    }

    // MARK: - The blocker state machine

    private func inputs(
        fullRequested: Bool = true,
        fullInstalled: Bool = true,
        fullConsented: Bool = true,
        fullDisabled: Bool = false,
        bundleActive: Bool = true,
        unavailable: Bool = false
    ) -> BundledExtensions.BlockingInputs {
        BundledExtensions.BlockingInputs(
            fullRequested: fullRequested,
            fullInstalled: fullInstalled,
            fullConsented: fullConsented,
            fullDisabled: fullDisabled,
            bundleActive: bundleActive,
            unavailable: unavailable
        )
    }

    /// The default: Lite blocks, and nothing about the injected bundle is touched. The
    /// request-blocking preference stays whatever the user set for other add-ons.
    @Test func fullOffLeavesLiteBlockingAndWritesNothing() {
        let plan = BundledExtensions.plan(for: inputs(fullRequested: false, fullInstalled: false))
        #expect(plan.activeBlocker == .lite)
        #expect(plan.installsFull == false)
        #expect(plan.requestBlocking == nil)
        #expect(plan.fullRequested == nil)
        #expect(plan.pending == .none)
    }

    /// Switching it on unpacks the archive and waits for the sheet. Lite keeps blocking
    /// in the meantime: a browser with no blocker at all is worse than the Lite build.
    @Test func switchingOnInstallsAndWaitsForConsent() {
        let plan = BundledExtensions.plan(for: inputs(fullInstalled: false, fullConsented: false))
        #expect(plan.installsFull)
        #expect(plan.activeBlocker == .lite)
        #expect(plan.requestBlocking == true)
        #expect(plan.pending == .consent)
    }

    /// Consented, but the injected bundle is only picked up at launch, so full uBO
    /// would block nothing yet. Lite stays on until the relaunch.
    @Test func consentedWithoutTheBundleWaitsForARelaunch() {
        let plan = BundledExtensions.plan(for: inputs(bundleActive: false))
        #expect(plan.activeBlocker == .lite)
        #expect(plan.requestBlocking == true)
        #expect(plan.pending == .relaunch)
    }

    /// The steady state: full uBO blocks, Lite is off. Never both, or the two rule sets
    /// fight over the same requests.
    @Test func installedConsentedAndLoadedHandsOverToFull() {
        let plan = BundledExtensions.plan(for: inputs())
        #expect(plan.activeBlocker == .full)
        #expect(plan.installsFull == false)
        #expect(plan.requestBlocking == true)
        #expect(plan.pending == .none)
    }

    /// Refusing the sheet leaves the extension installed and switched off, and that is
    /// what says the answer was no. Nothing changes: the switch goes back off and the
    /// injected bundle is not loaded on the next launch either.
    @Test func aRefusedSheetTakesTheSwitchBack() {
        let plan = BundledExtensions.plan(for: inputs(fullConsented: false, fullDisabled: true))
        #expect(plan.activeBlocker == .lite)
        #expect(plan.installsFull == false)
        #expect(plan.requestBlocking == false)
        #expect(plan.fullRequested == false)
        #expect(plan.pending == .none)
    }

    /// The health probe failing outranks the switch: Lite comes back for the session
    /// and neither stored setting is written, because a preference the app cleared
    /// behind the user's back would never turn itself on again.
    @Test func anUnavailableStackRestoresLiteAndKeepsBothSettings() {
        let plan = BundledExtensions.plan(for: inputs(unavailable: true))
        #expect(plan.activeBlocker == .lite)
        #expect(plan.requestBlocking == nil)
        #expect(plan.fullRequested == nil)
        #expect(plan.pending == .none)
    }

    /// Turning it off again is the same rule read backwards, with no relaunch prompt
    /// and no leftover state to chase.
    @Test func switchingBackOffReturnsToLite() {
        let running = BundledExtensions.plan(for: inputs())
        let off = BundledExtensions.plan(for: inputs(fullRequested: false))
        #expect(running.activeBlocker == .full)
        #expect(off.activeBlocker == .lite)
        #expect(off.pending == .none)
    }

    // MARK: - The paint verdict

    private func flatImage(red: Double, green: Double, blue: Double, side: Int = 16) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }

    private func fixtureImage() throws -> CGImage {
        let level = Double(AuraWebBundle.PaintProbe.fixtureLevel) / 255
        return try flatImage(red: level, green: level, blue: level)
    }

    /// Four quadrants: nothing flat, nothing the fixture colour.
    private func quadrantImage(side: Int = 16) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let colors: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0]]
        let half = CGFloat(side) / 2
        for (index, color) in colors.enumerated() {
            context.setFillColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
            context.fill(CGRect(
                x: CGFloat(index % 2) * half,
                y: CGFloat(index / 2) * half,
                width: half,
                height: half
            ))
        }
        return try #require(context.makeImage())
    }

    @Test func theFixtureColourReadsAsPainted() throws {
        let sample = AuraWebBundle.PaintProbe.sample(try fixtureImage())
        #expect(sample.pixels > 0)
        #expect(sample.fixtureShare > 0.99)
        #expect(AuraWebBundle.PaintProbe.reading(for: sample) == .painted)
    }

    /// What a purged layer tree leaves behind: one flat colour that the page never
    /// painted. White here, but black and fully transparent read the same way.
    @Test func aFlatWhiteImageReadsAsBlank() throws {
        let sample = AuraWebBundle.PaintProbe.sample(try flatImage(red: 1, green: 1, blue: 1))
        #expect(sample.fixtureShare == 0)
        #expect(sample.dominantShare > 0.99)
        #expect(AuraWebBundle.PaintProbe.reading(for: sample) == .blank)
    }

    /// Something is on screen, but not the fixture. Not proof of either, so nothing is
    /// switched off on it.
    @Test func aMixedImageIsInconclusive() throws {
        let sample = AuraWebBundle.PaintProbe.sample(try quadrantImage())
        #expect(AuraWebBundle.PaintProbe.reading(for: sample) == .inconclusive)
        #expect(AuraWebBundle.PaintProbe.reading(for: .init(pixels: 0, fixtureShare: 0, dominantShare: 0))
            == .inconclusive)
    }

    /// The only reading that takes blocking away is painted first, blank after. A
    /// surface that never painted at all is the probe's own failure, not the browser's,
    /// and a page still painting after the settle is simply healthy.
    @Test func onlyPaintedThenBlankCountsAgainstTheStack() throws {
        let painted = AuraWebBundle.PaintProbe.sample(try fixtureImage())
        let blank = AuraWebBundle.PaintProbe.sample(try flatImage(red: 1, green: 1, blue: 1))
        let verdict = AuraWebBundle.PaintProbe.verdict

        #expect(verdict(painted, blank) == .blank)
        #expect(verdict(painted, painted) == .painted)
        #expect(verdict(blank, blank) == .inconclusive)
        #expect(verdict(blank, painted) == .inconclusive)
    }

    /// The fixture page paints the colour the matcher looks for; the two are generated
    /// from one constant so they cannot drift apart.
    @Test func theFixturePageCarriesTheColourTheMatcherWants() {
        let level = AuraWebBundle.PaintProbe.fixtureLevel
        let hex = String(format: "#%02x%02x%02x", level, level, level)
        #expect(AuraWebBundle.PaintProbe.fixtureHTML.contains("background:\(hex)"))
    }
}
