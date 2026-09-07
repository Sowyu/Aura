import AppKit
import SwiftUI

/// One screen of the flow, picked by the draft's step. Each is its own view so the
/// card's transition sees a fresh identity per step.
struct OnboardingStepView: View {
    let draft: OnboardingDraft
    let finish: () -> Void

    var body: some View {
        switch draft.step {
        case .welcome: OnboardingWelcome(draft: draft)
        case .bring: OnboardingBring(draft: draft)
        case .style: OnboardingStyle(draft: draft)
        case .space: OnboardingSpace(draft: draft)
        case .favorites: OnboardingFavorites(draft: draft)
        case .blocking: OnboardingBlocking(draft: draft)
        case .finish: OnboardingFinish(draft: draft, finish: finish)
        }
    }
}

// MARK: - Page frame

/// The split card every screen after the title uses: copy and buttons on the left,
/// the interactive part on the right. The primary button owns Return.
private struct OnboardingPage<Content: View>: View {
    let title: String
    let message: String
    var primaryLabel = "Continue"
    let onPrimary: () -> Void
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme

    private let copyWidth: CGFloat = 300

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(theme.mutedForeground)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                VStack(alignment: .leading, spacing: 8) {
                    OraButton(
                        label: primaryLabel,
                        size: .lg,
                        keyboardShortcut: "return",
                        trailingIcon: "arrow.right",
                        action: onPrimary
                    )
                    .keyboardShortcut(.defaultAction)
                    OraButton(label: "Back", variant: .ghost, action: onBack)
                }
            }
            .padding(36)
            .frame(width: copyWidth, alignment: .topLeading)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(28)
                .background(theme.mutedBackground)
        }
    }
}

/// A radio card: one of a pair of real choices, never a disguised skip.
private struct OnboardingChoice: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? theme.accent : theme.mutedForeground)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.foreground)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                    .fill(isSelected ? theme.accent.opacity(0.12) : theme.solidWindowBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                    .stroke(isSelected ? theme.accent.opacity(0.8) : theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.row))
        .animation(AnimationSettings.easeOut(0.1), value: isSelected)
    }
}

private struct OnboardingLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(theme.mutedForeground)
            .textCase(.uppercase)
            .kerning(0.6)
    }
}

// MARK: - Welcome

/// The title card. No copy to read, one thing to press; the headline settles in with
/// a small stagger so the first frame is not a wall of text.
private struct OnboardingWelcome: View {
    let draft: OnboardingDraft

    @Environment(\.theme) private var theme
    @State private var settled = false

    var body: some View {
        VStack(spacing: 18) {
            Image("OraColorLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .settle(settled, delay: 0)
            VStack(spacing: 8) {
                Text("Welcome to Aura")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundColor(theme.foreground)
                    .settle(settled, delay: 0.12)
                Text("A browser that stays out of your way.")
                    .font(.system(size: 16))
                    .foregroundColor(theme.mutedForeground)
                    .settle(settled, delay: 0.24)
            }
            Button(action: draft.advance) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(theme.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(Text("Get started"))
            .padding(.top, 12)
            .settle(settled, delay: 0.4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { settled = true }
    }
}

private extension View {
    /// Fade and rise into place on a spring, `delay` seconds after the screen appears.
    func settle(_ settled: Bool, delay: Double) -> some View {
        opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 14)
            .animation(
                AnimationSettings.spring(response: 0.5, dampingFraction: 0.8)
                    .delay(AnimationSettings.duration(delay)),
                value: settled
            )
    }
}

// MARK: - Bring your things

/// Import and the default-browser question on one screen: both are the same
/// "moving in" decision, and neither deserves a screen to itself.
private struct OnboardingBring: View {
    @Bindable var draft: OnboardingDraft

    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(DialogManager.self) private var dialogManager
    @Environment(\.theme) private var theme

    var body: some View {
        OnboardingPage(
            title: "Bring your things.",
            message: "Your bookmarks are a map of the web you already know. Bring them along, and decide whether links from other apps should open here.",
            onPrimary: draft.advance,
            onBack: draft.goBack
        ) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingLabel(text: "Bookmarks")
                    HStack(spacing: 8) {
                        OraButton(label: "From Chrome, Firefox, Edge or Brave\u{2026}", variant: .secondary) {
                            importBookmarks(.netscapeHTML)
                        }
                        OraButton(label: "From Safari\u{2026}", variant: .secondary) {
                            importBookmarks(.safariPropertyList)
                        }
                    }
                    if draft.didImportBookmarks {
                        Label("Bookmarks imported", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.success)
                    } else {
                        Text(
                            "Export them from your old browser first; both are a file picker away. Skipping is fine, Settings › Bookmarks has the same buttons."
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    OnboardingLabel(text: "Default browser")
                    OnboardingChoice(
                        title: "Make Aura my default browser",
                        subtitle: "Links from other apps open here.",
                        isSelected: draft.makeDefaultBrowser
                    ) { draft.makeDefaultBrowser = true }
                    OnboardingChoice(
                        title: "Not yet",
                        subtitle: "I'm still looking around. Aura › Settings can do this later.",
                        isSelected: !draft.makeDefaultBrowser
                    ) { draft.makeDefaultBrowser = false }
                }
            }
        }
    }

    private func importBookmarks(_ format: BookmarkImportFormat) {
        Task {
            let before = bookmarkCount
            await BookmarkImportAction.run(format, store: bookmarkStore, dialogManager: dialogManager)
            if bookmarkCount > before { draft.didImportBookmarks = true }
        }
    }

    private var bookmarkCount: Int {
        bookmarkStore.rootBookmarks.count + bookmarkStore.folders.reduce(0) { $0 + $1.bookmarks.count }
    }
}

// MARK: - Style

/// Early on purpose: the accent recolours the room the card sits in, so every screen
/// after this one is already wearing the user's colour.
private struct OnboardingStyle: View {
    let draft: OnboardingDraft

    @EnvironmentObject private var appearanceManager: AppearanceManager

    var body: some View {
        OnboardingPage(
            title: "Make it yours.",
            message: "Pick a colour and watch the window take it. Light, dark or whatever your Mac is doing — all of this lives in Settings › Look and Feel too.",
            onPrimary: draft.advance,
            onBack: draft.goBack
        ) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingLabel(text: "Accent")
                    AccentPresetRow()
                }
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingLabel(text: "Appearance")
                    AppearanceSelector(selection: $appearanceManager.appearance)
                }
            }
        }
    }
}

// MARK: - First space

/// Names the space the profile already has rather than creating a second one: a new
/// user should not start with an empty "Default" they have to find and delete.
private struct OnboardingSpace: View {
    @Bindable var draft: OnboardingDraft

    @Environment(\.theme) private var theme
    @State private var isIconPickerOpen = false

    var body: some View {
        OnboardingPage(
            title: "Name your first space.",
            message: "A space is a sidebar of its own: work, home, a project. Give this one a name and an icon, or keep going and it stays \"Default\". More spaces are a click away at the bottom of the sidebar.",
            onPrimary: draft.advance,
            onBack: draft.goBack
        ) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingLabel(text: "Space")
                    ContainerForm(
                        name: $draft.spaceName,
                        emoji: $draft.spaceEmoji,
                        iconSymbol: $draft.spaceIconSymbol,
                        iconColorHex: $draft.spaceIconColorHex,
                        isIconPickerOpen: $isIconPickerOpen,
                        onSubmit: draft.advance,
                        defaultEmoji: ContainerConstants.defaultEmoji
                    )
                }
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingLabel(text: "In the sidebar")
                    preview
                }
            }
        }
    }

    /// The space header row as it will look, so the name and icon are seen in place.
    private var preview: some View {
        HStack(spacing: 8) {
            SpaceIconView(
                symbol: draft.spaceIconSymbol,
                colorHex: draft.spaceIconColorHex,
                emoji: draft.spaceEmoji,
                size: 14
            )
            .frame(width: 16, height: 16)
            Text(draft.spaceName.isEmpty ? "Default" : draft.spaceName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .frame(maxWidth: 220)
        .background(theme.foreground.opacity(0.06), in: .rect(cornerRadius: AuraRadius.row, style: .continuous))
    }
}

// MARK: - Favourites

private struct OnboardingFavorites: View {
    let draft: OnboardingDraft

    @Environment(\.theme) private var theme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        OnboardingPage(
            title: "Keep the sites you live in close.",
            message: "Favourites sit at the very top of the sidebar, in every list, one click away. Pick any, or none; nothing loads until you open it.",
            onPrimary: draft.advance,
            onBack: draft.goBack
        ) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(OnboardingSites.suggestions) { site in
                    tile(site, isSelected: draft.selectedSiteIDs.contains(site.id))
                }
            }
        }
    }

    private func tile(_ site: OnboardingSite, isSelected: Bool) -> some View {
        Button {
            draft.toggle(site)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: site.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(isSelected ? theme.accent : theme.foreground)
                Text(site.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(theme.foreground)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(
                RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                    .fill(isSelected ? theme.accent.opacity(0.14) : theme.solidWindowBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                    .stroke(isSelected ? theme.accent.opacity(0.8) : theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.row))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(AnimationSettings.easeOut(0.1), value: isSelected)
    }
}

// MARK: - Blocking

private struct OnboardingBlocking: View {
    @Bindable var draft: OnboardingDraft

    var body: some View {
        OnboardingPage(
            title: "Block the ads?",
            message: "uBlock Origin comes built in, so pages arrive faster and without the trackers riding along.",
            onPrimary: draft.advance,
            onBack: draft.goBack
        ) {
            VStack(alignment: .leading, spacing: 10) {
                OnboardingChoice(
                    title: "Yes, block them",
                    subtitle: "Ads and trackers stay out. Sites that need an exception get one from the toolbar.",
                    isSelected: draft.blockAds
                ) { draft.blockAds = true }
                OnboardingChoice(
                    title: "No, I collect banner ads",
                    subtitle: "Pages exactly as served. Settings › Privacy turns blocking back on any time.",
                    isSelected: !draft.blockAds
                ) { draft.blockAds = false }
            }
        }
    }
}

// MARK: - Finish

private struct OnboardingFinish: View {
    let draft: OnboardingDraft
    let finish: () -> Void

    @Environment(\.theme) private var theme

    private let shortcuts: [KeyboardShortcutDefinition] = [
        KeyboardShortcuts.Tabs.new,
        KeyboardShortcuts.App.toggleSidebar,
        KeyboardShortcuts.Window.toggleCompactMode
    ]

    var body: some View {
        OnboardingPage(
            title: "You're all set.",
            message: "Everything lives in the sidebar: favourites on top, pinned tabs under the space name, today's tabs below. Three keys worth knowing, and then the web is yours.",
            primaryLabel: "Dive in",
            onPrimary: finish,
            onBack: draft.goBack
        ) {
            ZStack {
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingLabel(text: "Worth knowing")
                    ForEach(shortcuts) { shortcut in
                        HStack {
                            Text(shortcut.name)
                                .font(.system(size: 13))
                                .foregroundColor(theme.foreground)
                            Spacer()
                            Text(shortcut.display)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(theme.foreground)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
                                        .fill(theme.solidWindowBackgroundColor)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
                                        .stroke(theme.border, lineWidth: 1)
                                )
                        }
                        .padding(.vertical, 4)
                    }
                }
                OnboardingConfetti()
            }
        }
    }
}
