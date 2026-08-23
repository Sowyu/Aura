import AppKit
import SwiftUI

/// The per-site JavaScript rows, shared by the "..." menu's submenu and the toolbar badge
/// so both offer exactly the same choices.
@MainActor
enum JavaScriptSiteMenu {
    /// Builds rows reflecting the rule in force for `url` right now.
    static func items(for url: URL?) -> [AuraMenuItem] {
        let service = JavaScriptPolicyService.shared
        guard let url, let host = url.host.map({ registrableDomain(from: $0) }), !host.isEmpty else {
            return [.disabled("No site loaded")]
        }

        let rule = service.rule(for: url)
        let isAllowed = service.isAllowed(for: url)
        // Only the side the default currently lands on is labelled as the default.
        let defaultSuffix = rule == nil ? " (default)" : ""

        return [
            .item(
                "Allow on \(host)" + (isAllowed ? defaultSuffix : ""),
                state: isAllowed ? .radioOn : .none
            ) {
                service.setRule(host: host, allowed: true)
            },
            .item(
                "Block on \(host)" + (isAllowed ? "" : defaultSuffix),
                state: isAllowed ? .none : .radioOn
            ) {
                service.setRule(host: host, allowed: false)
            },
            .separator,
            .item("Reset to Default", icon: "arrow.uturn.backward", isDisabled: rule == nil) {
                service.removeRule(host: host)
            }
        ]
    }
}

/// Toolbar badge shown only while the current site's scripts are off. Clicking it opens
/// the same rows as the "..." → JavaScript submenu.
struct JavaScriptBlockedBadge: View {
    let foregroundColor: Color
    let url: URL?
    var size: CGFloat = 28

    @ObservedObject private var policy = JavaScriptPolicyService.shared
    @State private var anchor: NSView?

    private var isBlocked: Bool {
        guard let url else { return false }
        return !policy.isAllowed(for: url)
    }

    var body: some View {
        if isBlocked {
            Button {
                anchor?.presentAuraMenu(JavaScriptSiteMenu.items(for: url))
            } label: {
                Image(systemName: "curlybraces")
                    .font(.system(size: URLBarButton.iconSize, weight: URLBarButton.iconWeight))
                    .foregroundColor(foregroundColor).opacity(URLBarButton.enabledOpacity)
                    .overlay {
                        // `nosign` over the braces: one glance says "scripts are off here".
                        Image(systemName: "line.diagonal")
                            .font(.system(size: URLBarButton.iconSize + 4, weight: .semibold))
                            .foregroundColor(.red.opacity(0.9))
                    }
                    .frame(width: size, height: size)
            }
            .buttonStyle(.interactive(cornerRadius: URLBarButton.cornerRadius, tint: foregroundColor))
            .background(AuraMenuAnchorView { anchor = $0 })
            .help("JavaScript is blocked on this site")
            .accessibilityLabel(Text("JavaScript blocked"))
        }
    }
}
