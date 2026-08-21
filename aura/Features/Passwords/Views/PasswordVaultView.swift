import SwiftUI

/// Unlock, search, reveal, copy and delete for the built-in credential vault.
///
/// The Passwords settings section and the standalone Passwords window each carried a
/// line-for-line copy of all of this, and the copies had already drifted: one showed a
/// Touch ID badge on the lock screen and the other did not, and the two unlock prompts
/// read differently. One view now, two hosts.
struct PasswordVaultView: View {
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
    @State private var pendingDelete: SavedPasswordSummary?

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
                    .font(.headline)
                if isUnlocked {
                    Text("\(visibleEntries.count) item\(visibleEntries.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(Color.secondary.opacity(0.75))

                if passwordManager.canUseBiometricAuthentication() {
                    Image(systemName: "touchid")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(Color(.windowBackgroundColor).opacity(0.92))
                        .clipShape(Circle())
                }
            }

            VStack(spacing: 8) {
                Text("Passwords Are Locked")
                    .font(.title3.weight(.semibold))

                Text("Use Touch ID or your Mac password to see your saved passwords.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
            if let lastErrorMessage = passwordManager.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
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
                        .overlay(Color(.separatorColor).opacity(0.7))

                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredEntries, id: \.id) { entry in
                                tableRow(entry, actionsColumnWidth: actionsColumnWidth)

                                if entry.id != filteredEntries.last?.id {
                                    Divider()
                                        .overlay(Color(.separatorColor).opacity(0.45))
                                        .padding(.leading, 12)
                                }
                            }
                        }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
            }
            .background(Color(.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separatorColor).opacity(0.55), lineWidth: 1)
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
        .background(Color(.controlBackgroundColor).opacity(0.3))
    }

    private func tableRow(_ entry: SavedPasswordSummary, actionsColumnWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                SiteFaviconView(host: entry.host, size: 20, cornerRadius: 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.host)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let origin = entry.origin {
                        Text(origin)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: Self.siteColumnWidth, alignment: .leading)

            HStack(spacing: 6) {
                Text(entry.displayUsername)
                    .font(.subheadline)
                    .foregroundStyle(entry.username.isEmpty ? .secondary : .primary)
                    .lineLimit(1)

                copyButton(help: "Copy username") {
                    passwordManager.copyToPasteboard(entry.username)
                }
            }
            .frame(width: Self.usernameColumnWidth, alignment: .leading)

            HStack(spacing: 6) {
                Text(revealedPasswordIDs[entry.id] ?? "••••••••••••")
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)

                Button {
                    toggleReveal(entry)
                } label: {
                    Image(systemName: revealedPasswordIDs[entry.id] == nil ? "eye" : "eye.slash")
                        .frame(width: 22, height: 22)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.interactive(cornerRadius: 5))
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
                .buttonStyle(.interactive(cornerRadius: 5))
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func copyButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OraIcons(icon: .copy, size: .custom(14), color: .secondary)
        }
        .buttonStyle(.interactive(cornerRadius: 5))
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
    }

    private func toggleReveal(_ entry: SavedPasswordSummary) {
        if revealedPasswordIDs[entry.id] != nil {
            revealedPasswordIDs[entry.id] = nil
            return
        }

        if let password = try? passwordManager.revealPassword(for: entry) {
            revealedPasswordIDs[entry.id] = password
        }
    }

    private func copyPassword(_ entry: SavedPasswordSummary) {
        if let password = try? passwordManager.revealPassword(for: entry) {
            passwordManager.copySensitiveToPasteboard(password)
        }
    }
}
