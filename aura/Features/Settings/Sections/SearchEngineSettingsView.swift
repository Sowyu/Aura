import AppKit
import SwiftUI

struct SearchEngineSettingsView: View {
    @Environment(\.theme) private var theme
    private let settings = SettingsStore.shared
    @StateObject private var searchEngineService = SearchEngineService()

    @State private var showingAddForm = false
    @State private var newEngineName = ""
    @State private var newEngineURL = ""
    @State private var newEngineAliases = ""
    @State private var newEngineIsAI = false

    private var isValidURL: Bool {
        newEngineURL
            .contains("{query}")
            && URL(string: newEngineURL.replacingOccurrences(of: "{query}", with: "test")) != nil
    }

    var body: some View {
        SettingsSection {
            SettingsCard {
                HStack {
                    Text("Search engine library")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(showingAddForm ? "Cancel" : "Add Custom Engine") {
                        if showingAddForm {
                            cancelForm()
                        } else {
                            showingAddForm = true
                        }
                    }
                }
            }

            if showingAddForm {
                SettingsCard(header: "Add new search engine") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Name:")
                                .frame(width: 80, alignment: .leading)
                            TextField("Search Engine Name", text: $newEngineName)
                        }

                        HStack {
                            Text("URL:")
                                .frame(width: 80, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(
                                    "https://example.com/search?q={query}",
                                    text: $newEngineURL
                                )
                                if !newEngineURL.isEmpty, !isValidURL {
                                    Text("URL must contain {query} and be a valid URL")
                                        .foregroundStyle(theme.destructive)
                                        .font(.system(size: 11))
                                }
                            }
                        }

                        HStack {
                            Text("Aliases:")
                                .frame(width: 80, alignment: .leading)
                            TextField("e.g., ddg, duck", text: $newEngineAliases)
                        }

                        HStack {
                            Text("Type:")
                                .frame(width: 80, alignment: .leading)
                            Toggle("AI Chat Engine", isOn: $newEngineIsAI)
                        }

                        HStack {
                            Spacer()
                            Button("Save") {
                                saveSearchEngine()
                            }
                            .disabled(newEngineName.isEmpty || !isValidURL)
                        }
                    }
                }
            }

            SettingsCard(header: "Default engines") {
                // Conventional Search Engines
                let conventionalEngines = searchEngineService.builtInSearchEngines.filter {
                    !$0.isAIChat
                }
                if !conventionalEngines.isEmpty {
                    Text("Conventional search engines")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
                        .padding(.bottom, 4)

                    ForEach(conventionalEngines, id: \.name) { engine in
                        BuiltInSearchEngineRow(
                            engine: engine,
                            isDefault: settings.globalDefaultSearchEngine
                                == engine
                                .name
                                || (settings.globalDefaultSearchEngine == nil
                                    && engine.name == "Google"
                                ),
                            onSetAsDefault: {
                                if engine.name == "Google" {
                                    settings.globalDefaultSearchEngine = nil
                                } else {
                                    settings.globalDefaultSearchEngine = engine.name
                                }
                            }
                        )
                    }
                }

                // AI Search Engines. No "Set as Default" here: the only default these
                // rows could write is `globalDefaultSearchEngine`, which is the plain
                // search default, so picking ChatGPT sent every ordinary query to it.
                // The AI default is per space, under Spaces.
                let aiEngines = searchEngineService.builtInSearchEngines.filter(\.isAIChat)
                if !aiEngines.isEmpty {
                    Text("AI search engines")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(aiEngines, id: \.name) { engine in
                        BuiltInSearchEngineRow(engine: engine, isDefault: false, onSetAsDefault: nil)
                    }

                    Text("Pick the AI chat each space uses under Settings › Spaces.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
                        .padding(.top, 4)
                }

                if !settings.customSearchEngines.isEmpty {
                    Divider()

                    Text("Custom search engines")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
                        .padding(.top, 8)
                }

                // Custom search engines
                ForEach(settings.customSearchEngines) { engine in
                    CustomSearchEngineRow(
                        engine: engine,
                        onDelete: {
                            if settings.globalDefaultSearchEngine == engine.name {
                                settings.globalDefaultSearchEngine = nil
                            }
                            settings.removeCustomSearchEngine(withId: engine.id)
                        },
                        onSetAsDefault: {
                            settings.globalDefaultSearchEngine = engine.name
                        },
                        isDefault: settings.globalDefaultSearchEngine == engine.name,
                        settings: settings
                    )
                }
            }
        }
    }

    private func clearForm() {
        newEngineName = ""
        newEngineURL = ""
        newEngineAliases = ""
        newEngineIsAI = false
    }

    private func cancelForm() {
        clearForm()
        showingAddForm = false
    }

    private func saveSearchEngine() {
        let aliasesList =
            newEngineAliases
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

        CustomSearchEngine.createWithFavicon(
            name: newEngineName,
            searchURL: newEngineURL,
            aliases: aliasesList,
            isAIChat: newEngineIsAI
        ) { [weak settings] engine in
            settings?.addCustomSearchEngine(engine)
        }

        clearForm()
        showingAddForm = false
    }
}

struct BuiltInSearchEngineRow: View {
    @Environment(\.theme) private var theme

    let engine: SearchEngine
    let isDefault: Bool
    /// `nil` for a row that cannot be made the default, e.g. the AI chat engines.
    let onSetAsDefault: (() -> Void)?

    var body: some View {
        HStack {
            // Favicon or icon
            Group {
                if !engine.icon.isEmpty {
                    Image(engine.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
                        .fill(engine.color.opacity(0.8))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Text(String(engine.name.first ?? "S"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                        )
                }
            }

            // Name and badges
            HStack(spacing: 8) {
                Text(engine.name)
                    .font(.system(size: 13))

                if isDefault {
                    Text("Default")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            theme.mutedBackground,
                            in: .rect(cornerRadius: AuraRadius.button, style: .continuous)
                        )
                }
            }

            Spacer()

            // Set as default button
            if !isDefault, let onSetAsDefault {
                Button("Set as Default", action: onSetAsDefault)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CustomSearchEngineRow: View {
    @Environment(\.theme) private var theme
    let engine: CustomSearchEngine
    let onDelete: () -> Void
    let onSetAsDefault: () -> Void
    let isDefault: Bool
    let settings: SettingsStore

    @State private var isEditing = false
    @State private var editName = ""
    @State private var editURL = ""
    @State private var editAliases = ""
    @State private var editIsAI = false

    private var isValidEditURL: Bool {
        editURL.contains("{query}")
            && URL(string: editURL.replacingOccurrences(of: "{query}", with: "test")) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEditing {
                // Inline edit form
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        // Favicon
                        Group {
                            if let favicon = engine.favicon {
                                Image(nsImage: favicon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            } else {
                                RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
                                    .fill(theme.mutedBackground)
                                    .frame(width: 16, height: 16)
                            }
                        }

                        Text("Edit search engine")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.mutedForeground)

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Name:")
                                .frame(width: 80, alignment: .leading)
                            TextField("Search Engine Name", text: $editName)
                        }

                        HStack {
                            Text("URL:")
                                .frame(width: 80, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("https://example.com/search?q={query}", text: $editURL)
                                if !editURL.isEmpty, !isValidEditURL {
                                    Text("URL must contain {query} and be a valid URL")
                                        .foregroundStyle(theme.destructive)
                                        .font(.system(size: 11))
                                }
                            }
                        }

                        HStack {
                            Text("Aliases:")
                                .frame(width: 80, alignment: .leading)
                            TextField("e.g., ddg, duck", text: $editAliases)
                        }

                        HStack {
                            Text("Type:")
                                .frame(width: 80, alignment: .leading)
                            Toggle("AI Chat Engine", isOn: $editIsAI)
                        }

                        HStack {
                            Spacer()
                            Button("Cancel") {
                                cancelEdit()
                            }
                            Button("Update") {
                                saveEdit()
                            }
                            .disabled(editName.isEmpty || !isValidEditURL)
                        }
                    }
                }
                .padding(12)
                .background(
                    theme.popoverMutedBackground,
                    in: .rect(cornerRadius: AuraRadius.row, style: .continuous)
                )
            } else {
                // Normal display
                HStack {
                    // Favicon
                    Group {
                        if let favicon = engine.favicon {
                            Image(nsImage: favicon)
                                .resizable()
                                .frame(width: 16, height: 16)
                        } else {
                            RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
                                .fill(theme.mutedBackground)
                                .frame(width: 16, height: 16)
                        }
                    }

                    // Name and badges
                    HStack(spacing: 8) {
                        Text(engine.name)
                            .font(.system(size: 13))
                        if isDefault {
                            Text("Default")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    theme.mutedBackground,
                                    in: .rect(cornerRadius: AuraRadius.button, style: .continuous)
                                )
                        }
                        if engine.isAIChat {
                            Text("AI")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.mutedForeground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    theme.mutedBackground,
                                    in: .rect(cornerRadius: AuraRadius.button, style: .continuous)
                                )
                        }
                    }

                    Spacer()

                    // Action buttons
                    HStack(spacing: 12) {
                        // Same reason the built-in AI rows have no button: the only
                        // default it could set is the plain search one.
                        if !isDefault, !engine.isAIChat {
                            Button("Set as Default") {
                                onSetAsDefault()
                            }
                        }

                        Button("Edit") {
                            startEdit()
                        }

                        Button("Delete", role: .destructive) {
                            onDelete()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            populateEditFields()
        }
    }

    private func startEdit() {
        populateEditFields()
        isEditing = true
    }

    private func cancelEdit() {
        isEditing = false
        populateEditFields()
    }

    private func populateEditFields() {
        editName = engine.name
        editURL = engine.searchURL
        editAliases = engine.aliases.joined(separator: ", ")
        editIsAI = engine.isAIChat
    }

    private func saveEdit() {
        let aliasesList =
            editAliases
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

        if editURL != engine.searchURL {
            CustomSearchEngine.createWithFavicon(
                id: engine.id,
                name: editName,
                searchURL: editURL,
                aliases: aliasesList,
                isAIChat: editIsAI
            ) { [weak settings] updatedEngine in
                settings?.updateCustomSearchEngine(updatedEngine)
            }
        } else {
            let updatedEngine = CustomSearchEngine(
                id: engine.id,
                name: editName,
                searchURL: editURL,
                aliases: aliasesList,
                faviconData: engine.faviconData,
                faviconBackgroundColorData: engine.faviconBackgroundColorData,
                isAIChat: editIsAI
            )
            settings.updateCustomSearchEngine(updatedEngine)
        }

        isEditing = false
    }
}
