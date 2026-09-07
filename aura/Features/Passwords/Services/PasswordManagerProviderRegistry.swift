import Foundation

enum PasswordManagerProviderKind: String, CaseIterable, Codable, Identifiable {
    case ora
    case onePassword
    case bitwarden

    var id: String {
        rawValue
    }
}

enum PasswordManagerAutofillMode {
    case builtInOverlay
    case nativeProviderOverlay
}

struct PasswordManagerProviderDescriptor: Identifiable, Hashable {
    let kind: PasswordManagerProviderKind
    let title: String
    let summary: String
    let vaultStoredInOra: Bool
    let autofillMode: PasswordManagerAutofillMode
    let isAvailable: Bool

    var id: PasswordManagerProviderKind {
        kind
    }

    var usesBuiltInVault: Bool {
        vaultStoredInOra
    }

    var usesBuiltInOverlay: Bool {
        autofillMode == .builtInOverlay
    }
}

final class PasswordManagerProviderRegistry {
    static let shared = PasswordManagerProviderRegistry()

    let providers: [PasswordManagerProviderDescriptor] = [
        PasswordManagerProviderDescriptor(
            kind: .ora,
            title: "Aura Passwords",
            summary: "Store encrypted credentials in Aura and show Aura's autofill overlay.",
            vaultStoredInOra: true,
            autofillMode: .builtInOverlay,
            isAvailable: true
        )
    ]

    private init() {}

    func descriptor(for kind: PasswordManagerProviderKind) -> PasswordManagerProviderDescriptor {
        providers.first(where: { $0.kind == kind }) ?? providers[0]
    }
}
