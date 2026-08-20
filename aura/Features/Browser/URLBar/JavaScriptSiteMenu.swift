import AppKit
import SwiftUI

/// The per-site JavaScript menu, shared by the "..." menu's submenu and the
/// toolbar badge so both offer exactly the same choices.
@MainActor
final class JavaScriptSiteMenu: NSObject {
    private var host: String?

    /// Builds a fresh menu reflecting the rule in force for `url` right now.
    static func makeMenu(for url: URL?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let service = JavaScriptPolicyService.shared
        guard let url, let host = url.host.map({ registrableDomain(from: $0) }), !host.isEmpty else {
            let item = NSMenuItem(title: "No site loaded", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }

        let owner = JavaScriptSiteMenu()
        owner.host = host
        let rule = service.rule(for: url)
        let isAllowed = service.isAllowed(for: url)
        let defaultSuffix = rule == nil ? " (default)" : ""

        let allow = owner.item(
            title: "Allow on \(host)" + (isAllowed ? defaultSuffix : ""),
            checked: isAllowed,
            action: #selector(allowSite)
        )
        // Retained here because NSMenuItem does not own its target.
        allow.representedObject = owner
        menu.addItem(allow)
        menu.addItem(owner.item(
            title: "Block on \(host)" + (isAllowed ? "" : defaultSuffix),
            checked: !isAllowed,
            action: #selector(blockSite)
        ))
        menu.addItem(.separator())
        let reset = owner.item(title: "Reset to Default", checked: false, action: #selector(resetSite))
        reset.isEnabled = rule != nil
        menu.addItem(reset)
        return menu
    }

    private func item(title: String, checked: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func allowSite() {
        guard let host else { return }
        JavaScriptPolicyService.shared.setRule(host: host, allowed: true)
    }

    @objc private func blockSite() {
        guard let host else { return }
        JavaScriptPolicyService.shared.setRule(host: host, allowed: false)
    }

    @objc private func resetSite() {
        guard let host else { return }
        JavaScriptPolicyService.shared.removeRule(host: host)
    }
}

/// Toolbar badge shown only while the current site's scripts are off. Clicking it
/// opens the same menu as the "..." → JavaScript submenu.
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
                guard let anchor else { return }
                JavaScriptSiteMenu.makeMenu(for: url)
                    .popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
            } label: {
                Image(systemName: "curlybraces")
                    .font(.system(size: URLBarButton.iconSize, weight: .medium))
                    .foregroundColor(foregroundColor.opacity(0.85))
                    .overlay {
                        // `nosign` over the braces: one glance says "scripts are off here".
                        Image(systemName: "line.diagonal")
                            .font(.system(size: URLBarButton.iconSize + 4, weight: .semibold))
                            .foregroundColor(.red.opacity(0.9))
                    }
                    .frame(width: size, height: size)
            }
            .buttonStyle(.interactive(cornerRadius: URLBarButton.cornerRadius, tint: foregroundColor))
            .background(JavaScriptBadgeAnchor { anchor = $0 })
            .help("JavaScript is blocked on this site")
            .accessibilityLabel(Text("JavaScript blocked"))
        }
    }
}

/// Flipped zero-content view the badge menu pops up from, so "just below the button"
/// is a single y value regardless of the host view's coordinate flip.
private struct JavaScriptBadgeAnchor: NSViewRepresentable {
    let onViewCreated: (NSView) -> Void

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        DispatchQueue.main.async { onViewCreated(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
