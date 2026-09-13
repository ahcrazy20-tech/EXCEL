import SwiftUI

/// List of AI providers with their free-tier info, key status and the primary selection.
struct AIProvidersView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var openProvider: AIProvider?

    var body: some View {
        List {
            if !settings.apiKeysLoaded {
                Section {
                    if let error = settings.apiKeyLoadError {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Button("ai.retry".loc) { Task { try? await settings.loadAPIKeys() } }
                    } else {
                        ProgressView("ai.loadingKeys".loc)
                    }
                }
            }
            Section {
                Toggle("ai.fallback".loc, isOn: $settings.aiFallbackEnabled)
                Text("ai.fallback.note".loc).font(.caption2).foregroundStyle(.secondary)
            }

            Section("ai.free".loc) {
                ForEach(AIProvider.ordered.filter { $0.isFree }, id: \.self) { provider in
                    row(provider)
                }
            }

            Section("ai.other".loc) {
                ForEach(AIProvider.ordered.filter { !$0.isFree }, id: \.self) { provider in
                    row(provider)
                }
            }

            Section {
                Text("settings.aiNote".loc).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task { try? await settings.loadAPIKeys() }
        .navigationTitle("settings.ai".loc)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $openProvider) { provider in
            AIProviderDetailView(provider: provider)
        }
    }

    private func row(_ provider: AIProvider) -> some View {
        Button {
            openProvider = provider
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: settings.hasKey(provider) ? "checkmark.seal.fill" : "key")
                    .foregroundStyle(settings.hasKey(provider) ? Color.green : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(provider.display).font(.body.weight(.medium))
                        if provider.isFree {
                            Text("ai.freeBadge".loc)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.18), in: Capsule())
                                .foregroundStyle(.green)
                        }
                        if settings.aiProvider == provider {
                            Text("ai.primary".loc)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                    }
                    Text(provider.quotaText)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if settings.hasKey(provider) {
                        Text(settings.model(for: provider))
                            .font(.caption2.monospaced()).foregroundStyle(.tint).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ai.provider.\(provider.rawValue)")
    }
}

/// Edits a draft. Testing never saves credentials or changes the primary provider.
struct AIProviderDetailView: View {
    let provider: AIProvider
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL

    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var models: [AIModelOption] = []
    @State private var initialized = false
    @State private var saving = false
    @State private var loadingModels = false
    @State private var testing = false
    @State private var testOK: Bool?
    @State private var testMessage = ""
    @State private var modelMessage = ""
    @State private var storageError: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var requestID = UUID()

    private var busy: Bool { loadingModels || testing }
    private var needsKey: Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && provider != .custom
    }

    var body: some View {
        NavigationStack {
            Form {
                if !initialized {
                    Section {
                        if let error = settings.apiKeyLoadError {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Button("ai.retry".loc) { Task { await initialize() } }
                        } else {
                            ProgressView("ai.loadingKeys".loc)
                        }
                    }
                }
                Section {
                    Text(provider.quotaText).font(.caption).foregroundStyle(.secondary)
                    if let url = provider.keyPageURL {
                        Button { openURL(url) } label: {
                            Label("ai.getKey".loc, systemImage: "safari")
                        }
                    }
                }

                Section("settings.apiKey".loc) {
                    SecureField("sk-…", text: $key)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("ai.apiKey")
                    Button(role: .destructive) { removeKey() } label: {
                        Text("ai.removeKey".loc)
                    }
                    .disabled(key.isEmpty && !settings.hasKey(provider))
                }
                .disabled(!initialized || saving)

                if provider == .custom {
                    Section("settings.baseURL".loc) {
                        TextField("https://…/v1", text: $baseURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .accessibilityIdentifier("ai.baseURL")
                    }
                    .disabled(!initialized || saving)
                }

                Section("settings.model".loc) {
                    TextField(provider.defaultModel, text: $model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("ai.model")
                    NavigationLink {
                        AIModelPickerView(models: models, selection: $model)
                    } label: {
                        Label("ai.chooseModel".loc, systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("ai.chooseModel")
                    Button { loadModels() } label: {
                        HStack {
                            Label("ai.fetchModels".loc, systemImage: "arrow.triangle.2.circlepath")
                            if loadingModels { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || needsKey || !initialized)
                    if !modelMessage.isEmpty {
                        Text(modelMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("ai.modelsHint".loc).font(.caption2).foregroundStyle(.secondary)
                }
                .disabled(saving)

                Section {
                    Button { test() } label: {
                        HStack {
                            Label("settings.test".loc, systemImage: "bolt.horizontal.circle")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || needsKey || !initialized || saving)
                    if busy {
                        Button("ai.cancelRequest".loc) { cancelRequest() }
                    }
                    if let testOK {
                        Label(testOK ? "ai.testOK".loc : "ai.testFail".loc,
                              systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.caption.bold())
                            .foregroundStyle(testOK ? Color.green : Color.red)
                        Text(testMessage).font(.caption).textSelection(.enabled)
                    }
                    Text("ai.testDraft".loc).font(.caption2).foregroundStyle(.secondary)
                }

                Section {
                    Button { save(makePrimary: true) } label: {
                        Label("ai.makePrimary".loc, systemImage: "star")
                    }
                    .disabled(!initialized || saving || busy)
                    if saving { ProgressView("ai.saving".loc) }
                }
            }
            .navigationTitle(provider.display)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".loc) { cancelRequest(); dismiss() }.disabled(saving)
                        .accessibilityIdentifier("ai.cancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("settings.save".loc) { save() }
                        .fontWeight(.semibold)
                        .disabled(!initialized || saving || busy)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .task { await initialize() }
        .onDisappear { cancelRequest() }
        .onChange(of: key) { _ in invalidateDraft(resetModels: true) }
        .onChange(of: baseURL) { _ in invalidateDraft(resetModels: true) }
        .onChange(of: model) { _ in invalidateDraft(resetModels: false) }
        .alert("common.error".loc, isPresented: Binding(
            get: { storageError != nil }, set: { if !$0 { storageError = nil } })) {
                Button("common.ok".loc, role: .cancel) {}
            } message: { Text(storageError ?? "") }
    }

    @MainActor
    private func initialize() async {
        guard !initialized else { return }
        model = settings.model(for: provider)
        baseURL = settings.baseURL(for: provider)
        models = suggestedModels
        do {
            try await settings.loadAPIKeys()
            try Task.checkCancellation()
            key = settings.apiKey(for: provider)
            initialized = true
        } catch { /* The shared loading error offers retry without discarding stored keys. */ }
    }

    private var suggestedModels: [AIModelOption] {
        provider.suggestedModels.map { AIModelOption(name: $0, isFree: provider.isFree) }
    }

    private var draftConfig: AIConfig {
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIConfig(provider: provider,
                        model: selected.isEmpty ? provider.defaultModel : selected,
                        baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func save(makePrimary: Bool = false) {
        guard !saving else { return }
        saving = true
        let config = draftConfig
        Task { @MainActor in
            defer { saving = false }
            do {
                try await settings.setAPIKey(config.apiKey, for: provider)
                settings.setModel(config.model, for: provider)
                if provider == .custom { settings.setBaseURL(config.baseURL, for: provider) }
                if makePrimary { settings.aiProvider = provider }
                settings.haptic(.medium)
                dismiss()
            } catch { storageError = error.localizedDescription }
        }
    }

    private func removeKey() {
        guard !saving else { return }
        cancelRequest()
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await settings.setAPIKey("", for: provider)
                key = ""
            } catch { storageError = error.localizedDescription }
        }
    }

    private func cancelRequest() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        loadingModels = false
        testing = false
    }

    private func invalidateDraft(resetModels: Bool) {
        cancelRequest()
        testOK = nil
        testMessage = ""
        if resetModels {
            models = suggestedModels
            modelMessage = ""
        }
    }

    private func loadModels() {
        cancelRequest()
        loadingModels = true
        modelMessage = ""
        let id = requestID
        let config = draftConfig
        requestTask = Task { @MainActor in
            defer { if requestID == id { loadingModels = false; requestTask = nil } }
            do {
                let list = try await AIModelDirectory.fetch(provider: provider,
                                                            baseURL: config.baseURL, apiKey: config.apiKey)
                try Task.checkCancellation()
                guard requestID == id else { return }
                models = list.isEmpty ? suggestedModels : list
                modelMessage = list.isEmpty ? "ai.noRemoteModels".loc
                    : String(format: "ai.modelsLoaded".loc, list.count)
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                modelMessage = "ai.modelsFailed".loc + "\n" + error.localizedDescription
            }
        }
    }

    private func test() {
        cancelRequest()
        testing = true
        testOK = nil
        let id = requestID
        let client = AIClient(config: draftConfig, requestTimeout: 20)
        let start = Date()
        requestTask = Task { @MainActor in
            defer { if requestID == id { testing = false; requestTask = nil } }
            do {
                let reply = try await client.complete(
                    system: "You are a connectivity check. Reply with exactly: ready",
                    user: "ping", jsonMode: false)
                try Task.checkCancellation()
                guard requestID == id else { return }
                testOK = true
                testMessage = String(format: "%.2fs · ", Date().timeIntervalSince(start))
                    + String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                settings.haptic(.medium)
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                testOK = false
                testMessage = error.localizedDescription
            }
        }
    }
}

/// A separate List keeps the provider form small and lazily creates model rows.
/// Search includes the entire catalogue, not just the first 40 entries.
struct AIModelPickerView: View {
    let models: [AIModelOption]
    @Binding var selection: String
    @Environment(\.dismiss) var dismiss
    @State private var search = ""
    @State private var freeOnly = false

    private var matches: [AIModelOption] {
        AIModelDirectory.matching(models, query: search, freeOnly: freeOnly)
    }

    var body: some View {
        List {
            Section {
                Toggle("ai.freeOnly".loc, isOn: $freeOnly)
                if !selection.isEmpty {
                    Text("\("ai.selectedModel".loc): \(selection)")
                        .font(.caption).textSelection(.enabled)
                }
            }
            Section {
                if matches.isEmpty {
                    Text("ai.noModelMatches".loc).foregroundStyle(.secondary)
                }
                ForEach(matches) { option in
                    Button {
                        selection = option.name
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Text(option.name).font(.callout).foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            if option.isFree {
                                Text("ai.freeBadge".loc).font(.caption2.bold()).foregroundStyle(.green)
                            }
                            if selection == option.name {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ai.modelOption.\(option.name)")
                    .accessibilityAddTraits(selection == option.name ? [.isSelected] : [])
                }
            } footer: {
                Text(String(format: "ai.modelCount".loc, matches.count, models.count))
            }
        }
        .navigationTitle("ai.chooseModel".loc)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "ai.searchModels".loc)
    }
}
