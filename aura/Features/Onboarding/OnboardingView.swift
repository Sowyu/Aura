import AppKit
import SwiftUI

extension View {
    /// The welcome flow, over everything in the window. Applied inside the window's
    /// environment stack and below the dialog stack on purpose: an import that fails
    /// or a blocker install that wants consent answers through dialogs, and those have
    /// to draw above the card.
    func onboarding() -> some View {
        modifier(OnboardingPresenter())
    }
}

private struct OnboardingPresenter: ViewModifier {
    @Environment(TabManager.self) private var tabManager
    @EnvironmentObject private var privacyMode: PrivacyMode

    private var settings: SettingsStore { SettingsStore.shared }

    private var isVisible: Bool {
        OnboardingPolicy.shouldShow(completed: settings.onboardingCompleted, isPrivate: privacyMode.isPrivate)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isVisible {
                    OnboardingView()
                        .transition(.opacity)
                }
            }
            .animation(AnimationSettings.easeOut(0.25), value: isVisible)
            .onAppear(perform: retireForExistingProfiles)
    }

    /// An upgrade is not a first run. Decided once, on first sight of an unfinished
    /// flag over a profile with history in it; after that the flag alone rules, which
    /// is what lets Settings › About replay the tour on a profile full of tabs.
    private func retireForExistingProfiles() {
        guard !settings.onboardingCompleted, !privacyMode.isPrivate else { return }
        let spaces = tabManager.fetchContainers()
        let tabsBeyondHome = spaces.flatMap(\.tabs).filter { !$0.url.isOraHome }.count
        if OnboardingPolicy.isExistingProfile(spaceCount: spaces.count, tabsBeyondHome: tabsBeyondHome) {
            settings.onboardingCompleted = true
        }
    }
}

/// The card and the room it sits in. Windowed, not a takeover: the browser window is
/// the frame, dimmed and blurred, with the accent bleeding through so the style screen
/// recolours the whole room live rather than a swatch.
struct OnboardingView: View {
    @Environment(\.theme) private var theme
    @Environment(\.window) private var window
    @Environment(TabManager.self) private var tabManager

    @State private var draft = OnboardingDraft()
    @State private var keyGuard: Any?

    private static let minCardSize = CGSize(width: 760, height: 500)
    private static let cardFraction: CGFloat = 0.72
    private static let margin: CGFloat = 24

    var body: some View {
        ZStack {
            backdrop
            GeometryReader { geo in
                card
                    .frame(width: cardWidth(in: geo.size), height: cardHeight(in: geo.size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: installKeyGuard)
        .onDisappear(perform: removeKeyGuard)
    }

    /// The card is modal but the chrome's shortcuts are not: ⌘T would open the
    /// launcher underneath it and ⌘W would close the tab it is sitting on. A local
    /// monitor runs before the menu bar sees a key, so swallowing the chord here is
    /// what keeps the menu equivalents out too. Scoped to this window, and only to
    /// command chords: plain keys are the name field's and Return is the button's.
    private func installKeyGuard() {
        guard keyGuard == nil else { return }
        let window = window
        keyGuard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard window == nil || event.window === window else { return event }
            return OnboardingKeyGuard.swallows(event) ? nil : event
        }
    }

    private func removeKeyGuard() {
        guard let keyGuard else { return }
        NSEvent.removeMonitor(keyGuard)
        self.keyGuard = nil
    }

    private var backdrop: some View {
        ZStack {
            // `withinWindow` is what reaches the page: a SwiftUI material sits above the
            // web view's layer and only tints it. Not click-through: the flow is modal.
            BlurEffectView(material: .hudWindow, blendingMode: .withinWindow)
            LinearGradient(
                colors: [theme.accent.opacity(0.45), theme.accent.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.18)
        }
        .animation(AnimationSettings.easeOut(0.3), value: theme.accent)
    }

    private var card: some View {
        OnboardingStepView(draft: draft, finish: finish)
            .id(draft.step)
            // Text travels right to left while the frame stays put: in from the
            // trailing edge, out through the leading one.
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(AnimationSettings.spring(response: 0.45, dampingFraction: 0.85), value: draft.step)
            .background(theme.solidWindowBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: AuraRadius.pane, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AuraRadius.pane, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
            .auraFloatingShadow()
    }

    private func cardWidth(in size: CGSize) -> CGFloat {
        min(max(size.width * Self.cardFraction, Self.minCardSize.width), size.width - Self.margin * 2)
    }

    private func cardHeight(in size: CGSize) -> CGFloat {
        min(max(size.height * Self.cardFraction, Self.minCardSize.height), size.height - Self.margin * 2)
    }

    private func finish() {
        OnboardingCommit.apply(draft, tabManager: tabManager)
        ToastManager.shared.show("Aura is set up. Enjoy.", icon: .system("sparkles"))
    }
}

/// Which key presses a window with the flow up keeps for itself.
enum OnboardingKeyGuard {
    /// Command chords that pass through: quitting, hiding and minimising belong to the
    /// app, not the card, and the editing set is what the space-name field runs on.
    static let passthrough: Set<String> = ["q", "h", "m", "a", "c", "v", "x", "z"]

    static func swallows(_ event: NSEvent) -> Bool {
        swallows(key: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
    }

    static func swallows(key: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.command) else { return false }
        guard let key = key?.lowercased(), !key.isEmpty else { return true }
        return !passthrough.contains(key)
    }
}
