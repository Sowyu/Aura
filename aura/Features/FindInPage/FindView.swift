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

    let tab: Tab

    private var findManager: FindManager { FindManager.shared }

    /// No match text only once a search has actually run and come back empty.
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
        .background(
            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                .fill(theme.popoverBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
        .auraFloatingShadow()
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
            .font(.system(size: 13))
            .frame(width: 200)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
                    .fill(theme.mutedBackground)
            )
            .foregroundColor(theme.foreground)
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

    private var textFieldBorder: some View {
        RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
            .stroke(isTextFieldFocused ? theme.accent : theme.border, lineWidth: 1)
    }

    /// Safari's find bar shows no "3 of 17" either: `WKFindResult` carries a single
    /// `matchFound` flag and no index or total, so the only honest states are "nothing
    /// matched" and nothing at all. The slot stays laid out at a fixed width so the bar
    /// does not resize while you type.
    private var matchCounter: some View {
        Text(showsNoMatches ? "No matches" : "")
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundColor(theme.mutedForeground)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 44, alignment: .trailing)
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            stepButton(icon: "chevron.up", forward: false)
            stepButton(icon: "chevron.down", forward: true)
        }
    }

    private func stepButton(icon: String, forward: Bool) -> some View {
        let isEnabled = !searchText.isEmpty && !showsNoMatches
        return Button(action: { findManager.step(in: tab, forward: forward) }) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isEnabled ? theme.foreground : theme.disabledForeground)
                .frame(width: 26, height: 26)
        }
        .disabled(!isEnabled)
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.mutedForeground)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
    }

    private func close() {
        findManager.close(tab)
        appState.showFinderIn = nil
    }
}
