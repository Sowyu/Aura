import Foundation
import Security
import SwiftUI
@testable import Aura
import Testing

/// Direct checks of the pure-logic bug fixes from the debug pass.
struct DebugPassRegressionTests {
    @Test func schemeCheckOnlyMatchesRealSchemes() {
        // "httpbin.org" starts with "http" but is a bare host — the old code
        // treated it as an absolute URL and extracted a nil/empty host.
        #expect(extractDomainOrIP(from: "httpbin.org") == "httpbin.org")
        #expect(extractDomainOrIP(from: "https://example.com/path") == "example.com")
        #expect(extractDomainOrIP(from: "http://example.com") == "example.com")
        #expect(extractDomainOrIP(from: "httpstat.us") == "httpstat.us")
    }

    @Test func findTermJSONEncodingSurvivesHostileInput() throws {
        // FindController JSON-encodes the term; verify the encoding round-trips
        // the characters that used to break the injected script.
        for term in ["back\\slash", "it's", "\"quoted\"", "line\nbreak", "</script>"] {
            let data = try JSONSerialization.data(withJSONObject: term, options: .fragmentsAllowed)
            let literal = try #require(String(data: data, encoding: .utf8))
            let decoded = try JSONSerialization.jsonObject(
                with: literal.data(using: .utf8)!, options: .fragmentsAllowed
            ) as? String
            #expect(decoded == term)
        }
    }

    @Test func hexColorFallbackIsOpaqueGray() {
        // Malformed hex used to produce a nearly transparent color.
        let color = Color(hex: "zz")
        #expect(NSColor(color).alphaComponent > 0.9)
    }

    /// `integer(forKey:)` reports 0 for "never set", so a user who really picked 0
    /// recent tabs used to get 5 back on every launch.
    @Test func storedZeroRecentTabsSurvivesReload() {
        let key = "settings.maxRecentTabs"
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set(0, forKey: key)
        #expect(SettingsStore().maxRecentTabs == 0)

        defaults.removeObject(forKey: key)
        #expect(SettingsStore().maxRecentTabs == 5)
    }

    /// A blob that will not decode used to silently reset the setting to empty, so one
    /// corrupt write wiped every custom search engine.
    @Test func corruptStoredBlobKeepsTheValueAlreadyInMemory() {
        let key = "settings.test.corruptBlob"
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: key) }
        defaults.set(Data("not json".utf8), forKey: key)

        let previous = [CustomSearchEngine(
            name: "Kept",
            searchURL: "https://example.com/?q={query}",
            aliases: ["kept"]
        )]

        #expect(SettingsStore.loadCodable([CustomSearchEngine].self, key: key, previous: previous)?.count == 1)
        // Nothing held in memory yet: the caller's own default still applies.
        #expect(SettingsStore.loadCodable([CustomSearchEngine].self, key: key) == nil)
    }

    /// `resolvedDownloadFolder` is called per download and by the save panel. It used to
    /// open a fresh security-scoped access every time and never close one.
    @Test func securityScopedFolderStartsAccessOncePerBookmark() throws {
        var starts: [URL] = []
        var stops: [URL] = []
        let folder = SecurityScopedFolder(
            start: { starts.append($0)
                return true
            },
            stop: { stops.append($0) }
        )

        let first = try #require(URL(string: "file:///tmp/first"))
        let second = try #require(URL(string: "file:///tmp/second"))
        let bookmarkA = Data("A".utf8)
        let bookmarkB = Data("B".utf8)
        var resolutions = 0

        for _ in 0 ..< 3 {
            #expect(folder.url(for: bookmarkA) { _ in resolutions += 1
                return first
            } == first)
        }
        #expect(starts == [first])
        #expect(stops.isEmpty)
        #expect(resolutions == 1)

        #expect(folder.url(for: bookmarkB) { _ in second } == second)
        #expect(starts == [first, second])
        #expect(stops == [first])

        folder.release()
        #expect(stops == [first, second])
    }

    /// A revealed password used to sit in view state until the user hid it again. It now
    /// hides itself, and sooner than the sensitive pasteboard clears.
    @Test func revealedPasswordAutoHidesBeforeThePasteboardClears() {
        #expect(PasswordVaultView.RevealPolicy.hideAfter == 60)
        #expect(PasswordVaultView.RevealPolicy.hideAfter
            < PasswordManagerService.sensitivePasteboardClearDelay)
    }

    /// `try?` on the delete used to swallow the keychain status, so the confirm sheet
    /// closed and the row looked gone even when nothing was removed.
    @MainActor @Test func failedDeleteReportsTheKeychainError() throws {
        // Already gone counts as deleted; anything else keeps the row.
        #expect(PasswordManagerService.deleteFailure(for: errSecSuccess) == nil)
        #expect(PasswordManagerService.deleteFailure(for: errSecItemNotFound) == nil)
        let failure = try #require(PasswordManagerService.deleteFailure(for: errSecAuthFailed))
        #expect(failure.localizedDescription.isEmpty == false)

        let manager = PasswordManagerService.shared
        defer { manager.refresh() }
        manager.report(failure)
        #expect(manager.lastErrorMessage == failure.localizedDescription)
    }

    /// Saved credentials used to be added with `kSecAttrSynchronizable` on, so every
    /// password left the device over iCloud Keychain without the user ever choosing it.
    /// The attribute now follows the setting, which is off unless asked for.
    @Test func newKeychainItemsSyncOnlyWhenTheSettingIsOn() {
        let metadata = SavedPasswordMetadata(
            id: "8B0B6E3E",
            origin: "https://example.com",
            host: "example.com",
            username: "someone@example.com",
            createdAt: Date(),
            updatedAt: Date(),
            lastUsedAt: nil,
            containerID: nil,
            passwordFingerprint: nil
        )

        let offDevice = PasswordManagerService.newItemAttributes(
            service: "com.orabrowser.app.passwords",
            metadata: metadata,
            encodedMetadata: Data("{}".utf8),
            password: "hunter2",
            syncsViaICloud: false
        )
        #expect(offDevice[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(offDevice[kSecAttrAccount as String] as? String == "8B0B6E3E")
        #expect(offDevice[kSecAttrLabel as String] as? String == "example.com")
        #expect(offDevice[kSecAttrComment as String] as? String == "someone@example.com")
        #expect(offDevice[kSecValueData as String] as? Data == Data("hunter2".utf8))

        let synced = PasswordManagerService.newItemAttributes(
            service: "com.orabrowser.app.passwords",
            metadata: metadata,
            encodedMetadata: Data("{}".utf8),
            password: "hunter2",
            syncsViaICloud: true
        )
        #expect(synced[kSecAttrSynchronizable as String] as? Bool == true)

        // Accessibility is unrelated to sync and must not drift with it: the autofill
        // overlay reads credentials without the user unlocking the Mac again.
        for item in [offDevice, synced] {
            #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        }
    }

    /// A profile that never touched the setting must not sync.
    @Test func passwordSyncIsOffOnAFreshProfile() {
        let key = "passwords.syncViaICloud"
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(SettingsStore().passwordSyncViaICloud == false)
    }
}

/// Second debug pass: updater state, password submit comparison, bridge payload encoding.
@Suite struct DebugPassTwoRegressionTests {
    // Bug 1: a clean "no update" result used to leave the check spinning until a 30
    // second fake timeout, because the updater delegate only implemented the
    // error-carrying selector. Aura's own Sparkle driver reports every outcome, so
    // every one of them leaves `.checking`.
    @Test func aCleanNoUpdateResultLeavesTheCheckingPhase() {
        let checkedAt = Date()
        #expect(UpdatePhase.checking.reducing(.upToDate(checkedAt: checkedAt))
            == .upToDate(checkedAt: checkedAt))
    }

    @Test func foundAndFailedOutcomesAlsoLeaveTheCheckingPhase() {
        #expect(UpdatePhase.checking.reducing(.updateFound(version: "2.0", stage: .notDownloaded))
            == .available(version: "2.0", notes: nil))
        #expect(UpdatePhase.checking.reducing(.failed(message: "offline")) == .failed(message: "offline"))
    }

    // Bug 2: every form submit revealed the saved password from the keychain to
    // compare it. The fingerprint answers the same question with no keychain read.
    @Test func fingerprintMatchesOnlyTheSavedPassword() {
        let fingerprint = SubmitComparison.fingerprint(for: "hunter2")
        #expect(SubmitComparison.matchesSavedPassword(typedPassword: "hunter2", savedFingerprint: fingerprint))
        #expect(!SubmitComparison.matchesSavedPassword(typedPassword: "hunter3", savedFingerprint: fingerprint))
        #expect(!SubmitComparison.matchesSavedPassword(typedPassword: "", savedFingerprint: fingerprint))
    }

    @Test func fingerprintIsSaltedSoTwoEntriesNeverShareADigest() {
        #expect(SubmitComparison.fingerprint(for: "hunter2") != SubmitComparison.fingerprint(for: "hunter2"))
    }

    @Test func missingOrMalformedFingerprintNeedsARevealAndNeverClaimsAMatch() {
        #expect(SubmitComparison.needsReveal(typedPassword: "hunter2", savedFingerprint: nil))
        #expect(SubmitComparison.needsReveal(typedPassword: "hunter2", savedFingerprint: "garbage"))
        #expect(!SubmitComparison.matchesSavedPassword(typedPassword: "hunter2", savedFingerprint: nil))
        #expect(!SubmitComparison.matchesSavedPassword(typedPassword: "hunter2", savedFingerprint: "garbage"))
        let fingerprint = SubmitComparison.fingerprint(for: "hunter2")
        #expect(!SubmitComparison.needsReveal(typedPassword: "hunter2", savedFingerprint: fingerprint))
    }

    // Bug 3: the payload was spliced into the script as raw JSON text, so a
    // password containing a quote, a backslash or U+2028 broke out of the literal.
    @Test func bridgePayloadSurvivesHostileCharacters() throws {
        let hostile = "\u{2028}\u{2029}\"'\\</script>\n\t\u{0}é😀"
        let payload = PasswordFillRequest(
            usernameFieldID: hostile,
            passwordFieldIDs: [hostile],
            username: hostile,
            password: hostile,
            highlightColor: hostile,
            submitAfterFill: true
        )

        let encoded = try #require(PasswordBridgeScript.base64Payload(payload))
        let script = PasswordBridgeScript.script(method: "fillCredentials", base64Payload: encoded)

        // Nothing hostile reaches the script text; base64 is quote-free and ASCII.
        #expect(!script.contains(hostile))
        #expect(!script.contains("</script>"))
        #expect(!script.contains("\u{2028}"))
        #expect(encoded.allSatisfy { $0.isASCII && $0 != "'" && $0 != "\\" })

        let data = try #require(Data(base64Encoded: encoded))
        let decoded = try JSONDecoder().decode(PasswordFillRequest.self, from: data)
        #expect(decoded.password == hostile)
        #expect(decoded.username == hostile)
        #expect(decoded.passwordFieldIDs == [hostile])
    }

    /// A wedged download never calls back, so nothing but this decision releases its
    /// task, its 10 Hz timer and the row stuck at "downloading".
    @MainActor @Test func stalledDownloadIsDroppedAfterFiveMinutes() {
        let start = Date()

        // Bytes still moving: never stalled, however long the transfer runs.
        #expect(!DownloadManager.hasStalled(
            bytes: 900, lastBytes: 800, lastMovedAt: start, now: start.addingTimeInterval(3600)
        ))
        // Same byte count, but inside the window.
        #expect(!DownloadManager.hasStalled(
            bytes: 800, lastBytes: 800, lastMovedAt: start, now: start.addingTimeInterval(299)
        ))
        #expect(DownloadManager.hasStalled(
            bytes: 800, lastBytes: 800, lastMovedAt: start, now: start.addingTimeInterval(300)
        ))
        // A transfer that has not started either: zero bytes counts the same.
        #expect(DownloadManager.hasStalled(
            bytes: 0, lastBytes: 0, lastMovedAt: start, now: start.addingTimeInterval(301)
        ))
        #expect(DownloadManager.stallTimeout == 300)
    }

    /// The row reads `displayProgress`. It used to be a `@Published` mirror written from a
    /// main-queue hop that no view subscribed to, so only the manager invalidating both
    /// download arrays at 10 Hz redrew it.
    @MainActor @Test func downloadProgressIsReadableImmediately() {
        let download = Download(originalURL: URL(string: "https://example.com/f.zip")!, fileName: "f.zip")

        download.updateProgress(downloadedBytes: 50, totalBytes: 200)

        #expect(download.displayDownloadedBytes == 50)
        #expect(download.displayFileSize == 200)
        #expect(download.displayProgress == 0.25)

        // No Content-Length: the last known size survives rather than becoming -1.
        download.updateProgress(downloadedBytes: 100, totalBytes: -1)
        #expect(download.displayFileSize == 200)
        #expect(download.displayProgress == 0.5)
    }
}
