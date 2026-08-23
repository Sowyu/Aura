import SwiftUI

struct GlobalMediaPlayer: View {
    @Environment(\.theme) var theme
    @Environment(MediaController.self) private var media
    @Environment(TabManager.self) private var tabManager

    @State private var isHovered: Bool = false

    /// Show up to 4 sessions when hovered, otherwise only the most recent one.
    /// Exclude the currently active tab's media session.
    private var sessionsToShow: [MediaController.Session] {
        let activeId = tabManager.activeTab?.id
        let visible = media.visibleSessions.filter { session in
            guard let activeId else { return true }
            return session.tabID != activeId
        }
        if isHovered { return Array(visible.prefix(4)) }
        return Array(visible.prefix(1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Show older session first so the most recent appears at the bottom
            ForEach(Array(sessionsToShow.reversed()), id: \.id) { session in
                MediaPlayerCard(
                    session: session,
                    isPrimary: session.tabID == sessionsToShow.first?.tabID
                )
                .environment(media)
                .environment(tabManager)
            }
        }
        .onHover { isHovered = $0 }
        .animation(AnimationSettings.easeOut(0.15), value: isHovered)
    }
}

private struct MediaPlayerCard: View {
    @Environment(\.theme) var theme
    @Environment(MediaController.self) private var media
    @Environment(TabManager.self) private var tabManager

    let session: MediaController.Session
    let isPrimary: Bool

    @State private var showVolume: Bool = false
    @State private var hovered: Bool = false

    private var faviconView: some View {
        if let url = session.favicon {
            return AnyView(
                AsyncImage(url: url) { image in
                    image.resizable()
                } placeholder: {
                    Image(systemName: "play.rectangle.fill")
                        .resizable()
                }
            )
        } else {
            return AnyView(
                Image(systemName: "play.rectangle.fill")
                    .resizable()
            )
        }
    }

    private func controlGlyph(_ name: String, isEnabled: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isEnabled ? theme.foreground : theme.disabledForeground)
            .frame(width: 24, height: 24)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.title.isEmpty {
                HStack(spacing: 8) {
                    Text(session.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Always laid out, only the opacity moves, so the title never shifts.
                    Button { media.closeSession(session.tabID) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.foreground)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }

            HStack {
                Button { tabManager.activateTab(id: session.tabID) } label: {
                    faviconView
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(4)
                }
                .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
                .help("Go to playing tab")

                Spacer()

                Button(action: { media.previousTrack(session.tabID) }) {
                    controlGlyph("backward.fill", isEnabled: media.canGoPrevious(of: session.tabID))
                }
                .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
                .disabled(!media.canGoPrevious(of: session.tabID))

                Button(action: { media.togglePlayPause(session.tabID) }) {
                    controlGlyph(session.isPlaying ? "pause.fill" : "play.fill", isEnabled: true)
                }
                .buttonStyle(.interactive(cornerRadius: AuraRadius.button))

                Button(action: { media.nextTrack(session.tabID) }) {
                    controlGlyph("forward.fill", isEnabled: media.canGoNext(of: session.tabID))
                }
                .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
                .disabled(!media.canGoNext(of: session.tabID))

                Spacer()

                Button {
                    withAnimation(AnimationSettings.easeOut(0.15)) { showVolume.toggle() }
                } label: {
                    controlGlyph(
                        media.volume(of: session.tabID) <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        isEnabled: true
                    )
                }
                .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if showVolume {
                Slider(value: Binding(
                    get: { media.volume(of: session.tabID) },
                    set: { media.setVolume(for: session.tabID, $0) }
                ), in: 0 ... 1)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                .fill(theme.mutedBackground)
        )
        .animation(AnimationSettings.easeOut(0.15), value: hovered)
        .onHover { hovered = $0 }
        .frame(maxWidth: .infinity)
    }
}
