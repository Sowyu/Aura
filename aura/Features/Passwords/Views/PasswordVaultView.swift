import SwiftUI

/// Unlock, search, reveal, copy and delete for the built-in credential vault.
///
/// The Passwords settings section and the standalone Passwords window each carried a
/// line-for-line copy of all of this, and the copies had already drifted: one showed a
/// Touch ID badge on the lock screen and the other did not, and the two unlock prompts
/// read differently. One view now, two hosts.
struct PasswordVaultView: View {
    @Environment(\.theme) private var theme
    let title: String
    /// Spaces to pick between. Passed in so each host keeps its own `@Query` order.
    let containers: [TabContainer]
    /// Fixed height for the table. The settings card sits inside the page's scroll view,
    /// where an unbounded height collapses the table's `GeometryReader` to nothing; the
    /// window hands it whatever space is left instead.
    var tableHeight: CGFloat?

    @StateObject private var passwordManager = PasswordManagerService.shared

    @State private var searchText = ""
    @State private var isUnlocked = false
    @State private var isAuthenticating = false
    @State private var selectedContainerId: UUID?
    @State private var revealedPasswordIDs: [String: String] = [:]
    /// One auto-hide task per revealed row, cancelled when the row is hidden by hand.
    @State private var revealTimers: [String: Task<Void, Never>] = [:]
    @State private var pendingDelete: SavedPasswordSummary?

    enum RevealPolicy {
        /// A plaintext password left on screen hides itself again after this long, which
        /// is sooner than a copied one leaves the pasteboard.
        static let hideAfter: TimeInterval = 60
    }

    private static let siteColumnWidth: CGFloat = 260
    private static let usernameColumnWidth: CGFloat = 220
    private static let passwordColumnWidth: CGFloat = 240
    private static let minimumTableContentWidth: CGFloat = 836
    private static let tableLeadingInset: CGFloat = 10
    private static let tableTrailingInset: CGFloat = 14

    private var selectedContainer: TabContainer? {
        containers.first { $0.id == selectedContainerId } ?? containers.first
    }

    private var visibleEntries: [SavedPasswordSummary] {
        passwordManager.entries(for: selectedContainer?.id)
    }

    private var filteredEntries: [SavedPasswordSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleEntries }

        return visibleEntries.filter { entry in
            entry.host.localizedCaseInsensitiveContains(query)
                || entry.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let lastErrorMessage = passwordManager.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.destructive)
            }

            if containers.isEmpty {
                emptyState(message: "Create a space to start storing passwords.")
            } else if isUnlocked {
                spacePickerRow

                TextField("Search saved passwords", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                if filteredEntries.isEmpty {
                    emptyState(message: searchText.isEmpty
                        ? "No saved passwords yet."
                        : "No saved passwords match that search.")
                } else {
                    passwordsTable
                }
            } else {
                lockedVaultState
            }
        }
        .onAppear {
            if selectedContainerId == nil {
                selectedContainerId = containers.first?.id
            }
        }
        .onChange(of: containers.map(\.id)) { _, containerIDs in
            guard let selectedContainerId else {
                self.selectedContainerId = containerIDs.first
                return
            }

            if !containerIDs.contains(selectedContainerId) {
                self.selectedContainerId = containerIDs.first
            }
        }
        // Relocking on the way out means a section switch or a window close does not
        // leave the vault open for whoever comes back to it.
        .onDisappear(perform: lockVault)
        .alert("Delete saved password?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    // A throw leaves the entry in place and puts the keychain's reason on
                    // the banner, rather than closing the sheet as if it had worked.
                    try? passwordManager.delete(pendingDelete)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            if let pendingDelete {
                Text("Remove the saved credential for \(pendingDelete.displayUsername) on \(pendingDelete.host)?")
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if isUnlocked {
                    Text("\(visibleEntries.count) item\(visibleEntries.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
                }
            }

            Spacer()

            if isUnlocked {
                Button("Lock", action: lockVault)
            }
        }
    }

    private var spacePickerRow: some View {
        HStack {
            Text("Space")
            Spacer()
            Picker("", selection: Binding(
                get: { selectedContainerId ?? containers.first?.id },
                set: { selectedContainerId = $0 }
            )) {
                ForEach(containers) { container in
                    Text("\(container.emoji) \(container.name)").tag(Optional(container.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 220, alignment: .trailing)
        }
    }

    private var lockedVaultState: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(theme.mutedForeground)

                if passwordManager.canUseBiometricAuthentication() {
                    Image(systemName: "touchid")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(theme.background)
                        .clipShape(Circle())
                }
            }

            VStack(spacing: 8) {
                Text("Passwords are locked")
                    .font(.system(size: 15, weight: .semibold))

                Text("Use Touch ID or your Mac password to see your saved passwords.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            OraButton(
                label: isAuthenticating ? "Unlocking..." : "Unlock Passwords",
                variant: .outline,
                isDisabled: isAuthenticating,
                leadingIcon: passwordManager.canUseBiometricAuthentication() ? "touchid" : "lock.open"
            ) {
                unlockVault()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
    }

    private func emptyState(message: String) -> some View {
        Text(message)
            .foregroundStyle(theme.mutedForeground)
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
    }

    // MARK: - Table

    private var passwordsTable: some View {
        GeometryReader { geometry in
            let contentWidth = max(Self.minimumTableContentWidth, geometry.size.width)
            let actionsColumnWidth = max(52, contentWidth - 784)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    tableHeader(actionsColumnWidth: actionsColumnWidth)

                    Divider()
                        .overlay(theme.border)

                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredEntries, id: \.id) { entry in
                                tableRow(entry, actionsColumnWidth: actionsColumnWidth)

                                if entry.id != filteredEntries.last?.id {
                                    Divider()
                                        .overlay(theme.border)
                                        .padding(.leading, 12)
                                }
                            }
                        }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
            }
            .background(theme.popoverBackground)
            .clipShape(RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: tableHeight ?? 0, maxHeight: tableHeight ?? .infinity)
    }

    private func tableHeader(actionsColumnWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            headerCell("Site", width: Self.siteColumnWidth)
            headerCell("Username", width: Self.usernameColumnWidth)
            headerCell("Password", width: Self.passwordColumnWidth)
            headerCell("Actions", width: actionsColumnWidth)
        }
        .padding(.leading, Self.tableLeadingInset)
        .padding(.trailing, Self.tableTrailingInset)
        .padding(.vertical, 12)
        .background(theme.mutedBackground)
    }

    private func tableRow(_ entry: SavedPasswordSummary, actionsColumnWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                SiteFaviconView(host: entry.host, size: 20, cornerRadius: AuraRadius.button)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.host)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let origin = entry.origin {
                        Text(origin)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.mutedForeground)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: Self.siteColumnWidth, alignment: .leading)

            HStack(spacing: 6) {
                Text(entry.displayUsername)
                    .font(.system(size: 13))
                    .foregroundStyle(entry.username.isEmpty ? theme.mutedForeground : theme.foreground)
                    .lineLimit(1)

                copyButton(help: "Copy username") {
                    passwordManager.copyToPasteboard(entry.username)
                }
            }
            .frame(width: Self.usernameColumnWidth, alignment: .leading)

            HStack(spacing: 6) {
                Text(revealedPasswordIDs[entry.id] ?? "••••••••••••")
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)

                Button {
                    toggleReveal(entry)
                } label: {
                    Image(systemName: revealedPasswordIDs[entry.id] == nil ? "eye" : "eye.slash")
                        .frame(width: 22, height: 22)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.mutedForeground)
                }
                .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
                .help(revealedPasswordIDs[entry.id] == nil ? "Reveal password" : "Hide password")

                copyButton(help: "Copy password") {
                    copyPassword(entry)
                }
            }
            .frame(width: Self.passwordColumnWidth, alignment: .leading)

            HStack {
                Button(role: .destructive) {
                    pendingDelete = entry
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 22, height: 22)
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
                .help("Delete saved password")
            }
            .frame(width: actionsColumnWidth, alignment: .leading)
        }
        .padding(.leading, Self.tableLeadingInset)
        .padding(.trailing, Self.tableTrailingInset)
        .padding(.vertical, 12)
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.mutedForeground)
            .frame(width: width, alignment: .leading)
    }

    private func copyButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OraIcons(icon: .copy, size: .custom(14), color: .secondary)
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
        .help(help)
    }

    // MARK: - Actions

    private func unlockVault() {
        isAuthenticating = true
        Task {
            let authenticated = await passwordManager.authenticate(reason: "Unlock your saved passwords in Aura")
            await MainActor.run {
                isUnlocked = authenticated
                isAuthenticating = false
                if authenticated {
                    passwordManager.refresh()
                }
            }
        }
    }

    private func lockVault() {
        isUnlocked = false
        isAuthenticating = false
        searchText = ""
        revealedPasswordIDs.removeAll()
        revealTimers.values.forEach { $0.cancel() }
        revealTimers.removeAll()
    }

    private func toggleReveal(_ entry: SavedPasswordSummary) {
        if revealedPasswordIDs[entry.id] != nil {
            hideReveal(entry.id)
            return
        }

        do {
            revealedPasswordIDs[entry.id] = try passwordManager.revealPassword(for: entry)
            revealTimers[entry.id]?.cancel()
            revealTimers[entry.id] = Task {
                try? await Task.sleep(for: .seconds(RevealPolicy.hideAfter))
                guard !Task.isCancelled else { return }
                hideReveal(entry.id)
            }
        } catch {
            passwordManager.report(error)
        }
    }

    private func hideReveal(_ id: String) {
        revealedPasswordIDs[id] = nil
        revealTimers.removeValue(forKey: id)?.cancel()
    }

    private func copyPassword(_ entry: SavedPasswordSummary) {
        do {
            passwordManager.copySensitiveToPasteboard(try passwordManager.revealPassword(for: entry))
        } catch {
            passwordManager.report(error)
        }
    }
}
