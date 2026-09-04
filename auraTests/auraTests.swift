//
//  oraTests.swift
//  oraTests
//
//  Created by keni on 6/21/25.
//

import Foundation
@testable import Aura
import Testing

struct OraTests {
    @Test func normalizesHostsForPasswordMatching() {
        #expect(PasswordManagerService.normalizeHost("WWW.Example.COM.") == "www.example.com")
        #expect(PasswordManagerService.normalizeHost(" login.example.com ") == "login.example.com")
    }

    @Test func normalizesOriginsForPasswordMatching() throws {
        let secureURL = try #require(URL(string: "https://WWW.Example.COM/login"))
        let defaultPortURL = try #require(URL(string: "https://example.com:443/account"))
        let customPortURL = try #require(URL(string: "https://example.com:8443/account"))
        let insecureURL = try #require(URL(string: "http://example.com/login"))
        let unsupportedURL = try #require(URL(string: "file:///tmp/index.html"))

        #expect(PasswordManagerService.normalizedOrigin(from: secureURL) == "https://www.example.com")
        #expect(PasswordManagerService.normalizedOrigin(from: defaultPortURL) == "https://example.com")
        #expect(PasswordManagerService.normalizedOrigin(from: customPortURL) == "https://example.com:8443")
        #expect(PasswordManagerService.normalizedOrigin(from: insecureURL) == "http://example.com")
        #expect(PasswordManagerService.normalizedOrigin(from: unsupportedURL) == nil)
    }

    @Test func generatesStrongPasswords() {
        let password = PasswordManagerService.generateStrongPassword()

        #expect(password.count >= 12)
        #expect(password.contains("-") || password.rangeOfCharacter(from: .decimalDigits) != nil)
    }

    @Test func warnsBeforeSavingPasswordsOnInsecurePages() throws {
        let insecureURL = try #require(URL(string: "http://example.com/login"))

        let prompt = PasswordAutofillCoordinator.savePromptDetails(
            for: insecureURL,
            username: "alice@example.com",
            normalizedHost: "example.com",
            isUpdate: false
        )

        #expect(prompt.showsSecurityWarning)
        #expect(prompt.title == "Save Password on Insecure Page")
        #expect(prompt.confirmButtonTitle == "Save Anyway")
        #expect(prompt.neverButtonTitle == "Never on This Site")
        #expect(prompt.message.contains("insecure connection (http://)"))
    }

    @Test func keepsStandardPromptOnSecurePages() throws {
        let secureURL = try #require(URL(string: "https://example.com/login"))

        let prompt = PasswordAutofillCoordinator.savePromptDetails(
            for: secureURL,
            username: "",
            normalizedHost: "example.com",
            isUpdate: true
        )

        #expect(prompt.showsSecurityWarning == false)
        #expect(prompt.title == "Update Password")
        #expect(prompt.confirmButtonTitle == "Update Password")
        #expect(prompt.neverButtonTitle == "Never on This Site")
        #expect(prompt.message == "Update the saved password for example.com?")
    }

    @Test func recognizesEmailUsernamesForSignupSuggestions() {
        #expect(PasswordManagerService.looksLikeEmail("alice@example.com"))
        #expect(PasswordManagerService.looksLikeEmail(" alice@example.com "))
        #expect(PasswordManagerService.looksLikeEmail("alice") == false)
        #expect(PasswordManagerService.looksLikeEmail("alice@localhost") == false)
    }

    @Test func limitsSignupSuggestionsByFocusedFieldKind() {
        let entry = SavedPasswordSummary(
            metadata: SavedPasswordMetadata(
                id: "entry-1",
                origin: "https://example.com",
                host: "example.com",
                username: "saved@example.com",
                createdAt: .distantPast,
                updatedAt: .distantPast,
                lastUsedAt: nil
            ),
            persistentReference: Data()
        )
        let emailSuggestion = PasswordEmailSuggestion(
            email: "person@example.com",
            host: "another.com",
            lastUsedAt: nil,
            updatedAt: .distantPast
        )

        let passwordFocus = PasswordBridgeFocusPayload(
            fieldID: "password-field",
            hostname: "example.com",
            action: .createAccount,
            fieldKind: .password,
            usernameFieldID: "email-field",
            passwordFieldIDs: ["password-field"],
            rect: PasswordBridgeRect(originX: 0, originY: 0, width: 100, height: 20)
        )
        let passwordSuggestions = PasswordAutofillCoordinator.resolveSuggestions(
            for: passwordFocus,
            matchingEntries: [entry],
            emailSuggestions: [emailSuggestion],
            generatedPassword: "StrongPass123!"
        )

        #expect(passwordSuggestions.generatedPassword == "StrongPass123!")
        #expect(passwordSuggestions.savedPasswordEntries.isEmpty)
        #expect(passwordSuggestions.emailSuggestions.isEmpty)

        let emailFocus = PasswordBridgeFocusPayload(
            fieldID: "email-field",
            hostname: "example.com",
            action: .createAccount,
            fieldKind: .email,
            usernameFieldID: "email-field",
            passwordFieldIDs: ["password-field"],
            rect: PasswordBridgeRect(originX: 0, originY: 0, width: 100, height: 20)
        )
        let emailSuggestions = PasswordAutofillCoordinator.resolveSuggestions(
            for: emailFocus,
            matchingEntries: [entry],
            emailSuggestions: [emailSuggestion],
            generatedPassword: "StrongPass123!"
        )

        #expect(emailSuggestions.generatedPassword == nil)
        #expect(emailSuggestions.savedPasswordEntries.isEmpty)
        #expect(emailSuggestions.emailSuggestions == [emailSuggestion])
    }

    @Test func storesPrivacySettingsPerSpaceIndependently() {
        let store = SettingsStore.shared
        let firstContainerID = UUID()
        let secondContainerID = UUID()
        let baselineSecondSettings = store.privacySettings(for: secondContainerID)

        defer {
            store.removeContainerSettings(for: firstContainerID)
            store.removeContainerSettings(for: secondContainerID)
        }

        let updatedSettings = SpacePrivacySettings(
            blockThirdPartyTrackers: true,
            blockFingerprinting: true,
            cookiesPolicy: .blockThirdParty
        )

        store.setPrivacySettings(updatedSettings, for: firstContainerID)

        #expect(store.privacySettings(for: firstContainerID) == updatedSettings)
        #expect(store.privacySettings(for: secondContainerID) == baselineSecondSettings)
    }

    @Test func removingContainerSettingsResetsSpacePrivacyOverrides() {
        let store = SettingsStore.shared
        let containerID = UUID()
        let baselineSettings = store.privacySettings(for: containerID)

        defer {
            store.removeContainerSettings(for: containerID)
        }

        var updatedSettings = baselineSettings
        updatedSettings.cookiesPolicy = baselineSettings.cookiesPolicy == .blockAll ? .allowAll : .blockAll
        updatedSettings.blockThirdPartyTrackers.toggle()

        store.setPrivacySettings(updatedSettings, for: containerID)
        #expect(store.privacySettings(for: containerID) == updatedSettings)

        store.removeContainerSettings(for: containerID)
        #expect(store.privacySettings(for: containerID) == baselineSettings)
    }

    @Test func spacePrivacySettingsDefaultToFingerprintingOnAndCookiesAllowed() {
        let defaults = SpacePrivacySettings()

        #expect(defaults.blockFingerprinting)
        #expect(defaults.cookiesPolicy == .allowAll)
    }

    @Test func fingerprintingEnabledSpacesGenerateProtectionScripts() {
        // Global Privacy Control has a script of its own; off, so only fingerprinting counts.
        let disabledScripts = BrowserPrivacyService.privacyScripts(
            for: SpacePrivacySettings(blockFingerprinting: false, globalPrivacyControl: false)
        )
        let enabledScripts = BrowserPrivacyService.privacyScripts(
            for: SpacePrivacySettings(blockFingerprinting: true, globalPrivacyControl: false)
        )

        #expect(disabledScripts.isEmpty)
        #expect(enabledScripts.count == 1)
        #expect(enabledScripts.first?.source.isEmpty == false)
    }

    @Test func fingerprintingScriptDoesNotDependOnCookiePolicy() {
        let allowAllScript = BrowserPrivacyService.privacyScripts(
            for: SpacePrivacySettings(blockFingerprinting: true, cookiesPolicy: .allowAll)
        ).first?.source
        let blockAllScript = BrowserPrivacyService.privacyScripts(
            for: SpacePrivacySettings(blockFingerprinting: true, cookiesPolicy: .blockAll)
        ).first?.source

        #expect(allowAllScript == blockAllScript)
    }

    @Test func balancedFingerprintingProfileIsInternallyCoherent() {
        let profile = FingerprintingProtectionProfile.balanced

        #expect(profile.language == profile.languages.first)
        #expect(profile.availWidth <= profile.screenWidth)
        #expect(profile.availHeight <= profile.screenHeight)
        #expect(profile.devicePixelRatio > 0)
        #expect(profile.platform == "MacIntel")
        #expect(profile.vendor == "Apple Computer, Inc.")
        #expect(profile.mediaDeviceKinds == ["audioinput", "audiooutput", "videoinput"])
    }

    @Test func fingerprintingScriptIncludesBalancedSurfaceNormalization() {
        let script = BrowserPrivacyService.fingerprintingProtectionScriptSource()

        #expect(script.contains("hardwareConcurrency"))
        #expect(script.contains("devicePixelRatio"))
        #expect(script.contains("enumerateDevices"))
        #expect(script.contains("toDataURL"))
        #expect(script.contains("OfflineAudioContext"))
        #expect(script.contains("WebGLRenderingContext"))
    }

    @Test func trackerRegexMatchesRootAndSubdomains() throws {
        let pattern = BrowserPrivacyService.regexForDomain("hotjar.com")
        let regex = try NSRegularExpression(pattern: pattern)
        let rootURL = "https://hotjar.com/script.js"
        let subdomainURL = "https://static.hotjar.com/c/hotjar.js"
        let otherURL = "https://not-hotjar-example.com/script.js"

        let rootRange = NSRange(rootURL.startIndex ..< rootURL.endIndex, in: rootURL)
        let subdomainRange = NSRange(subdomainURL.startIndex ..< subdomainURL.endIndex, in: subdomainURL)
        let otherRange = NSRange(otherURL.startIndex ..< otherURL.endIndex, in: otherURL)

        #expect(regex.firstMatch(in: rootURL, range: rootRange) != nil)
        #expect(regex.firstMatch(in: subdomainURL, range: subdomainRange) != nil)
        #expect(regex.firstMatch(in: otherURL, range: otherRange) == nil)
    }
}
