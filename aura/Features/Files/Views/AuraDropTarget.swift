import AppKit
import SwiftUI

/// A drop target for addresses, files and dragged text.
///
/// The payload is read straight off the drag pasteboard rather than out of SwiftUI's item
/// providers, for two reasons: providers load asynchronously, and they cannot see Aura's
/// own `.auraTabItem` type at all, which is the one type every receiver has to recognise
/// so a sidebar row being reordered is not mistaken for an address to open.
///
/// Where this lands in the view hierarchy matters. AppKit offers a drop to the deepest
/// registered view under the pointer first, so a web view keeps the drops the page itself
/// handles (an upload area, an editor) and this only sees what WebKit turned down.
private struct AuraDropTarget: ViewModifier {
    let handle: (DropPayload) -> Bool

    @State private var isTargeted = false
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .onDrop(of: DropPayloadReader.acceptedContentTypes, isTargeted: $isTargeted) { _ in
                handle(DropPayloadReader.classify(NSPasteboard(name: .drag)))
            }
            .overlay {
                if isTargeted {
                    Rectangle()
                        .strokeBorder(theme.accent.opacity(0.6), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .animation(AnimationSettings.easeOut(0.1), value: isTargeted)
    }
}

extension View {
    /// Accepts dropped addresses, files and text. Returns true from `handle` when the drop
    /// was used, which is what tells the sender the drag succeeded.
    func auraDropTarget(_ handle: @escaping (DropPayload) -> Bool) -> some View {
        modifier(AuraDropTarget(handle: handle))
    }
}
