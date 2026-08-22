//
//  FindView.swift
//  aura
//
//  Created by keni on 7/28/25.
//

import SwiftUI

struct FindView: View {
    @State private var searchText = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(AppState.self) private var appState
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) var colorScheme

    let tab: Tab

    private var findManager: FindManager { FindManager.shared }

    /// No match badge only once a search has actually run and come back empty.
    private var showsNoMatches: Bool {
        !searchText.isEmpty && !findManager.session(for: tab.id).matched
    }

    var body: some View {
        HStack(spacing: 12) {
            searchTextField
            matchCounter
            navigationButtons
            closeButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(backgroundView)
        .overlay(borderView)
        .shadow(
            color: .black.opacity(0.15),
            radius: 12,
            x: 0,
            y: 4
        )
        .onAppear {
            // The term the tab was last searched for, so reopening the bar (or coming
            // back from another tab) picks up where it left off.
            searchText = findManager.session(for: tab.id).query
            // Still deferred (SwiftUI needs the window's first responder to settle first),
            // just not 150 ms of dead typing time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTextFieldFocused = true
            }
        }
        .onChange(of: tab.id) { _, _ in
            searchText = findManager.session(for: tab.id).query
        }
        .zIndex(1000)
    }

    private var searchTextField: some View {
        TextField("Find in page", text: $searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 200)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(textFieldBackground)
            .foregroundColor(theme.foreground)
            .cornerRadius(8)
            .overlay(textFieldBorder)
            .focused($isTextFieldFocused)
            .onChange(of: searchText) { _, newValue in
                findManager.search(newValue, in: tab)
            }
            .onSubmit {
                findManager.step(in: tab, forward: true)
            }
            .onKeyPress(.escape) {
                close()
                return .handled
            }
            .onKeyPress(.upArrow) {
                findManager.step(in: tab, forward: false)
                return .handled
            }
            .onKeyPress(.downArrow) {
                findManager.step(in: tab, forward: true)
                return .handled
            }
    }

    private var textFieldBackground: some View {
        Rectangle()
            .fill(theme.mutedBackground)
    }

    private var textFieldBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(
                isTextFieldFocused
                    ? theme.foreground.opacity(0.2)
                    : theme.border,
                lineWidth: 1
            )
    }

    /// Safari's find bar shows no "3 of 17" either: `WKFindResult` carries a single
    /// `matchFound` flag and no index or total, so the only honest states are "nothing
    /// matched" and nothing at all.
    private var matchCounter: some View {
        HStack {
            if showsNoMatches {
                noMatchesBadge
            } else {
                // Invisible placeholder so the bar does not resize as you type.
                Text("")
                    .font(.system(size: 12, weight: .bold))
                    .opacity(0)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 80)
    }

    private var noMatchesBadge: some View {
        Text("No matches")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                BlurEffectView(
                    material: .popover,
                    blendingMode: .withinWindow
                )
            )
            .cornerRadius(6)
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            stepButton(icon: "chevron.up", forward: false)
            buttonSeparator
            stepButton(icon: "chevron.down", forward: true)
        }
        .background(navigationButtonsBackground)
    }

    private func stepButton(icon: String, forward: Bool) -> some View {
        let isEnabled = !searchText.isEmpty && !showsNoMatches
        return Button(action: { findManager.step(in: tab, forward: forward) }) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .disabled(!isEnabled)
        .buttonStyle(EnhancedFindButtonStyle(colorScheme: colorScheme, isEnabled: isEnabled))
    }

    private var buttonSeparator: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 1, height: 20)
    }

    private var navigationButtonsBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.foreground.opacity(0.6))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.interactive(cornerRadius: 6))
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.background.opacity(0.6))
            )
    }

    private var borderView: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(theme.border, lineWidth: 1)
    }

    private func close() {
        findManager.close(tab)
        appState.showFinderIn = nil
    }
}

struct EnhancedFindButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
    let isEnabled: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(buttonForegroundColor(configuration))
            .background(buttonBackgroundColor(configuration))
            .cornerRadius(4)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1.0)
            .animation(AnimationSettings.easeOut(0.1), value: configuration.isPressed)
            .animation(AnimationSettings.easeOut(0.15), value: isHovering)
            .onHover { hovering in
                if isEnabled {
                    isHovering = hovering
                }
            }
    }

    private func buttonForegroundColor(_ configuration: Configuration) -> Color {
        if !isEnabled {
            return colorScheme == .dark ? .white.opacity(0.3) : .black.opacity(0.3)
        } else if configuration.isPressed {
            return colorScheme == .dark ? .white : .black
        } else if isHovering {
            return colorScheme == .dark ? .white.opacity(0.9) : .black.opacity(0.8)
        } else {
            return colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.6)
        }
    }

    private func buttonBackgroundColor(_ configuration: Configuration) -> Color {
        if !isEnabled {
            return Color.clear
        } else if configuration.isPressed {
            return colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.1)
        } else if isHovering {
            return colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05)
        } else {
            return Color.clear
        }
    }
}
