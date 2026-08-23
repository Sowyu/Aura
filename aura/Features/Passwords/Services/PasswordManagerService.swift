import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SwiftData

struct SavedPasswordMetadata: Codable, Hashable {
    var id: String
    var origin: String?
    var host: String
    var username: String
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var containerID: UUID?
    /// Salted digest of the stored password. Lets a form submit tell "same password
    /// as saved" apart from "changed" without reading the secret back out of the
    /// keychain. Nil for entries saved before this existed.
    var passwordFingerprint: String?
}

struct SavedPasswordSummary: Identifiable, Hashable {
    let metadata: SavedPasswordMetadata
    let persistentReference: Data

    var id: String {
        metadata.id
    }

    var host: String {
        metadata.host
    }

    var origin: String? {
        metadata.origin
    }

    var username: String {
        metadata.username
    }

    var createdAt: Date {
        metadata.createdAt
    }

    var updatedAt: Date {
        metadata.updatedAt
    }

    var lastUsedAt: Date? {
        metadata.lastUsedAt
    }

    var containerID: UUID? {
        metadata.containerID
    }

    var displayUsername: String {
        username.isEmpty ? "No username" : username
    }

    var passwordFingerprint: String? {
        metadata.passwordFingerprint
    }
}

/// Compares a submitted password against a saved entry without touching the keychain.
/// A fingerprint is `salt.SHA256(salt + password)`, both base64.
enum SubmitComparison {
    private static let separator: Character = "."

    static func fingerprint(for password: String) -> String {
        var salt = Data(count: 16)
        let generated = salt.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base) == errSecSuccess
        }
        guard generated else {
            // Fail closed: no salt means no usable fingerprint, so submits fall back
            // to prompting rather than to a silent match.
            return ""
        }
        return fingerprint(for: password, salt: salt)
    }

    static func fingerprint(for password: String, salt: Data) -> String {
        let digest = SHA256.hash(data: salt + Data(password.utf8))
        return salt.base64EncodedString() + String(separator) + Data(digest).base64EncodedString()
    }

    /// True only when the stored fingerprint proves the typed password is the one
    /// already saved. Anything unparseable answers false, never a match.
    static func matchesSavedPassword(typedPassword: String, savedFingerprint: String?) -> Bool {
        guard let salt = salt(from: savedFingerprint), let savedFingerprint else { return false }
        return fingerprint(for: typedPassword, salt: salt) == savedFingerprint
    }

    /// True when the entry carries no usable fingerprint, so the only way to decide
    /// is an authenticated keychain reveal. The submit path treats this as "changed"
    /// and prompts instead, which backfills the fingerprint on save.
    static func needsReveal(typedPassword: String, savedFingerprint: String?) -> Bool {
        salt(from: savedFingerprint) == nil
    }

    private static func salt(from fingerprint: String?) -> Data? {
        guard let fingerprint else { return nil }
        let parts = fingerprint.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return Data(base64Encoded: String(parts[0]))
    }
}

struct PasswordEmailSuggestion: Identifiable, Hashable {
    let email: String
    let host: String
    let lastUsedAt: Date?
    let updatedAt: Date

    var id: String {
        email.lowercased()
    }
}

final class PasswordManagerService: ObservableObject {
    static let shared = PasswordManagerService()

    @Published private(set) var entries: [SavedPasswordSummary] = []
    @Published private(set) var lastErrorMessage: String?

    private let serviceName = "com.orabrowser.app.passwords"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        refresh()
    }

    func refresh() {
        do {
            let loadedEntries = try loadEntries()
            if try migrateLegacyEntriesIfNeeded(loadedEntries) {
                entries = try loadEntries()
            } else {
                entries = loadedEntries
            }
            lastErrorMessage = nil
        } catch {
            entries = []
            lastErrorMessage = error.localizedDescription
        }
    }

    func matchingEntries(for url: URL) -> [SavedPasswordSummary] {
        matchingEntries(for: url, containerID: nil)
    }

    func matchingEntries(for url: URL, containerID: UUID?) -> [SavedPasswordSummary] {
        guard let origin = Self.normalizedOrigin(from: url),
              let host = Self.normalizedHost(from: url)
        else {
            return []
        }

        let shouldAllowLegacyHostMatch = Self.isSecureDefaultPort(url)
        let alternateHost = host.hasPrefix("www.")
            ? String(host.dropFirst(4))
            : "www.\(host)"

        return scopedEntries(for: containerID)
            .filter { entry in
                if entry.origin == origin {
                    return true
                }

                guard shouldAllowLegacyHostMatch, entry.origin == nil else {
                    return false
                }

                let entryHost = Self.normalizeHost(entry.host)
                return entryHost == host || entryHost == alternateHost
            }
            .sorted {
                let lhsDate = $0.lastUsedAt ?? $0.updatedAt
                let rhsDate = $1.lastUsedAt ?? $1.updatedAt
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return $0.displayUsername.localizedCaseInsensitiveCompare($1.displayUsername) == .orderedAscending
            }
    }

    func emailSuggestions(limit: Int = 4) -> [PasswordEmailSuggestion] {
        emailSuggestions(for: nil, limit: limit)
    }

    func emailSuggestions(for containerID: UUID?, limit: Int = 4) -> [PasswordEmailSuggestion] {
        var seenEmails = Set<String>()

        return scopedEntries(for: containerID)
            .sorted {
                let lhsDate = $0.lastUsedAt ?? $0.updatedAt
                let rhsDate = $1.lastUsedAt ?? $1.updatedAt
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return $0.displayUsername.localizedCaseInsensitiveCompare($1.displayUsername) == .orderedAscending
            }
            .compactMap { entry -> PasswordEmailSuggestion? in
                let trimmedEmail = entry.username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.looksLikeEmail(trimmedEmail) else {
                    return nil
                }

                let normalizedEmail = trimmedEmail.lowercased()
                guard seenEmails.insert(normalizedEmail).inserted else {
                    return nil
                }

                return PasswordEmailSuggestion(
                    email: trimmedEmail,
                    host: entry.host,
                    lastUsedAt: entry.lastUsedAt,
                    updatedAt: entry.updatedAt
                )
            }
            .prefix(limit)
            .map(\.self)
    }

    func entries(for containerID: UUID?) -> [SavedPasswordSummary] {
        scopedEntries(for: containerID)
    }

    /// Lets a caller that handled a throw itself put the reason on the shared banner,
    /// so the vault has one place to read failures from.
    func report(_ error: Error) {
        lastErrorMessage = error.localizedDescription
    }

    func revealPassword(for entry: SavedPasswordSummary) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: entry.persistentReference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw PasswordManagerError.keychainStatus(status)
        }

        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            throw PasswordManagerError.invalidStoredPassword
        }

        return password
    }

    func upsertCredential(for url: URL, username: String, password: String) throws {
        try upsertCredential(for: url, username: username, password: password, containerID: nil)
    }

    func upsertCredential(for url: URL, username: String, password: String, containerID: UUID?) throws {
        guard let normalizedOrigin = Self.normalizedOrigin(from: url),
              let normalizedHost = Self.normalizedHost(from: url)
        else {
            throw PasswordManagerError.invalidCredentialOrigin
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        if let existing = scopedEntries(for: containerID, includeLegacyFallback: true).first(where: {
            let originMatches = $0.origin == normalizedOrigin
            let legacyHostMatches = $0.origin == nil && Self.normalizeHost($0.host) == normalizedHost
            return (originMatches || legacyHostMatches) && $0.username == trimmedUsername
        }) {
            let metadata = SavedPasswordMetadata(
                id: existing.id,
                origin: normalizedOrigin,
                host: normalizedHost,
                username: trimmedUsername,
                createdAt: existing.createdAt,
                updatedAt: now,
                lastUsedAt: existing.lastUsedAt,
                containerID: containerID,
                passwordFingerprint: SubmitComparison.fingerprint(for: password)
            )

            let attributes: [String: Any] = try [
                kSecAttrGeneric as String: encode(metadata: metadata),
                kSecAttrLabel as String: normalizedHost,
                kSecAttrComment as String: trimmedUsername,
                kSecValueData as String: Data(password.utf8)
            ]

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecValuePersistentRef as String: existing.persistentReference
            ]

            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw PasswordManagerError.keychainStatus(status)
            }
        } else {
            let metadata = SavedPasswordMetadata(
                id: UUID().uuidString,
                origin: normalizedOrigin,
                host: normalizedHost,
                username: trimmedUsername,
                createdAt: now,
                updatedAt: now,
                lastUsedAt: nil,
                containerID: containerID,
                passwordFingerprint: SubmitComparison.fingerprint(for: password)
            )

            let item = try Self.newItemAttributes(
                service: serviceName,
                metadata: metadata,
                encodedMetadata: encode(metadata: metadata),
                password: password,
                syncsViaICloud: SettingsStore.shared.passwordSyncViaICloud
            )

            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw PasswordManagerError.keychainStatus(status)
            }
        }

        refresh()
    }

    func markUsed(_ entry: SavedPasswordSummary) {
        do {
            let metadata = SavedPasswordMetadata(
                id: entry.id,
                origin: entry.origin,
                host: entry.host,
                username: entry.username,
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt,
                lastUsedAt: Date(),
                containerID: entry.containerID,
                passwordFingerprint: entry.passwordFingerprint
            )

            let attributes: [String: Any] = try [
                kSecAttrGeneric as String: encode(metadata: metadata)
            ]
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecValuePersistentRef as String: entry.persistentReference
            ]

            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw PasswordManagerError.keychainStatus(status)
            }

            refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func delete(_ entry: SavedPasswordSummary) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: entry.persistentReference
        ]

        if let failure = Self.deleteFailure(for: SecItemDelete(query as CFDictionary)) {
            // Recorded here rather than at the call site so every caller reports the same
            // failure, and the row stays put because the throw skips the refresh.
            lastErrorMessage = failure.localizedDescription
            throw failure
        }

        refresh()
    }

    /// The attributes for a credential Aura is storing for the first time.
    ///
    /// Split out as a pure function because `kSecAttrSynchronizable` decides whether the
    /// password, the host and the username leave this Mac, and that is worth a test that
    /// does not need a keychain. Only new and re-saved items pass through here: an item
    /// that is already synced stays synced, since flipping the setting off and silently
    /// pulling credentials out of iCloud Keychain would surprise anyone relying on them.
    static func newItemAttributes(
        service: String,
        metadata: SavedPasswordMetadata,
        encodedMetadata: Data,
        password: String,
        syncsViaICloud: Bool
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: metadata.id,
            // Autofill runs without a second unlock, so the item has to survive the
            // first one. Unrelated to sync, and it does not move with it.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock as String,
            kSecAttrSynchronizable as String: syncsViaICloud,
            kSecAttrGeneric as String: encodedMetadata,
            kSecAttrLabel as String: metadata.host,
            kSecAttrComment as String: metadata.username,
            kSecValueData as String: Data(password.utf8)
        ]
    }

    /// errSecItemNotFound means the credential is already gone, which is the outcome the
    /// caller asked for. Any other status leaves the entry in place.
    static func deleteFailure(for status: OSStatus) -> PasswordManagerError? {
        status == errSecSuccess || status == errSecItemNotFound
            ? nil
            : .keychainStatus(status)
    }

    func deleteEntries(for containerID: UUID) throws {
        let scopedEntries = entries(for: containerID)

        defer {
            refresh()
        }

        do {
            for entry in scopedEntries {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecValuePersistentRef as String: entry.persistentReference
                ]

                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw PasswordManagerError.keychainStatus(status)
                }
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func generateStrongPassword() -> String {
        Self.generateStrongPassword()
    }

    static func generateStrongPassword() -> String {
        if let generated = SecCreateSharedWebCredentialPassword() as String? {
            return generated
        }

        // Reached only when the Security framework declines. Ambiguous characters
        // (0/O, 1/l/I, 2/Z) are left out so the password stays readable aloud.
        let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let lowercase = Array("abcdefghijkmnopqrstuvwxyz")
        let digits = Array("3456789")
        let symbols = Array("!@#$%^&*")
        let allCharacters = uppercase + lowercase + digits + symbols

        var password = [
            uppercase.randomElement(),
            lowercase.randomElement(),
            digits.randomElement(),
            symbols.randomElement()
        ].compactMap { $0 }

        while password.count < 20 {
            if let character = allCharacters.randomElement() {
                password.append(character)
            }
        }

        return String(password.shuffled())
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Fail closed: if the device cannot authenticate, do not expose the vault.
            return false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    func canUseBiometricAuthentication() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func currentAccountDisplayName() -> String {
        NSFullUserName()
    }

    func copyToPasteboard(_ value: String) {
        copyToPasteboard(value, clearingAfter: nil)
    }

    /// How long a copied password stays on the pasteboard.
    static let sensitivePasteboardClearDelay: TimeInterval = 90

    func copySensitiveToPasteboard(_ value: String) {
        copyToPasteboard(value, clearingAfter: Self.sensitivePasteboardClearDelay)
    }

    static func normalizeHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func normalizedHost(from url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else {
            return nil
        }
        return normalizeHost(host)
    }

    static func normalizedOrigin(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = normalizedHost(from: url)
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host

        if let port = url.port, port != defaultPort(for: scheme) {
            components.port = port
        }

        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func looksLikeEmail(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              let atIndex = trimmedValue.firstIndex(of: "@")
        else {
            return false
        }

        let localPart = trimmedValue[..<atIndex]
        let domainStart = trimmedValue.index(after: atIndex)
        guard domainStart < trimmedValue.endIndex else {
            return false
        }

        let domainPart = trimmedValue[domainStart...]
        return !localPart.isEmpty
            && domainPart.contains(".")
            && !domainPart.hasPrefix(".")
            && !domainPart.hasSuffix(".")
    }

    private func loadEntries() throws -> [SavedPasswordSummary] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordManagerError.keychainStatus(status)
        }

        guard let records = result as? [[String: Any]] else {
            return []
        }

        return records.compactMap { record -> SavedPasswordSummary? in
            guard let persistentReference = record[kSecValuePersistentRef as String] as? Data else {
                return nil
            }

            if let genericData = record[kSecAttrGeneric as String] as? Data,
               let metadata = try? decoder.decode(SavedPasswordMetadata.self, from: genericData)
            {
                return SavedPasswordSummary(metadata: metadata, persistentReference: persistentReference)
            }

            guard let account = record[kSecAttrAccount as String] as? String,
                  let host = record[kSecAttrLabel as String] as? String
            else {
                return nil
            }

            let fallbackMetadata = SavedPasswordMetadata(
                id: account,
                origin: nil,
                host: host,
                username: record[kSecAttrComment as String] as? String ?? "",
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast,
                lastUsedAt: nil,
                containerID: nil
            )
            return SavedPasswordSummary(metadata: fallbackMetadata, persistentReference: persistentReference)
        }
        .sorted {
            if $0.host != $1.host {
                return $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending
            }
            return $0.displayUsername.localizedCaseInsensitiveCompare($1.displayUsername) == .orderedAscending
        }
    }

    private func encode(metadata: SavedPasswordMetadata) throws -> Data {
        try encoder.encode(metadata)
    }

    private func scopedEntries(for containerID: UUID?, includeLegacyFallback: Bool = false) -> [SavedPasswordSummary] {
        guard let containerID else {
            return entries
        }

        return entries.filter { entry in
            if entry.containerID == containerID {
                return true
            }

            return includeLegacyFallback && entry.containerID == nil
        }
    }

    private func migrateLegacyEntriesIfNeeded(_ loadedEntries: [SavedPasswordSummary]) throws -> Bool {
        let legacyEntries = loadedEntries.filter { $0.containerID == nil }
        guard !legacyEntries.isEmpty,
              let destinationContainerID = legacyMigrationContainerID()
        else {
            return false
        }

        for entry in legacyEntries {
            let metadata = SavedPasswordMetadata(
                id: entry.id,
                origin: entry.origin,
                host: entry.host,
                username: entry.username,
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt,
                lastUsedAt: entry.lastUsedAt,
                containerID: destinationContainerID,
                passwordFingerprint: entry.passwordFingerprint
            )

            let attributes: [String: Any] = try [
                kSecAttrGeneric as String: encode(metadata: metadata)
            ]
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecValuePersistentRef as String: entry.persistentReference
            ]

            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw PasswordManagerError.keychainStatus(status)
            }
        }

        return true
    }

    private func legacyMigrationContainerID() -> UUID? {
        guard let modelContainer = try? ModelConfiguration.createOraContainer(isPrivate: false) else {
            return nil
        }

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<TabContainer>(
            sortBy: [SortDescriptor(\TabContainer.createdAt, order: .forward)]
        )

        return try? context.fetch(descriptor).first?.id
    }

    private func copyToPasteboard(_ value: String, clearingAfter timeout: TimeInterval?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        guard let timeout else {
            return
        }

        let expectedChangeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            let currentPasteboard = NSPasteboard.general
            guard currentPasteboard.changeCount == expectedChangeCount,
                  currentPasteboard.string(forType: .string) == value
            else {
                return
            }

            currentPasteboard.clearContents()
        }
    }

    private static func isSecureDefaultPort(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else {
            return false
        }

        return url.port == nil || url.port == defaultPort(for: "https")
    }

    private static func defaultPort(for scheme: String) -> Int {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return -1
        }
    }
}

enum PasswordManagerError: LocalizedError {
    case invalidStoredPassword
    case invalidCredentialOrigin
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredPassword:
            return "Aura couldn't decode the stored password."
        case .invalidCredentialOrigin:
            return "Aura can only save passwords for web origins."
        case let .keychainStatus(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain error \(status)."
        }
    }
}
