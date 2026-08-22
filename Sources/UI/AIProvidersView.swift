import SwiftUI

/// List of AI providers with their free-tier info, key status and the primary selection.
struct AIProvidersView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var openProvider: AIProvider?

    var body: some View {
        List {
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
    }
}

/// Key entry + live model picker + connection test for one provider.
struct AIProviderDetailView: View {
    let provider: AIProvider
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL

    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var models: [AIModelOption] = []
    @State private var loadingModels = false
    @State private var testing = false
    @State private var testOK: Bool?
    @State private var testMessage = ""
    @State private var elapsed: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(provider.quotaText).font(.caption).foregroundStyle(.secondary)
                    if let url = provider.keyPageURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("ai.getKey".loc, systemImage: "safari")
                        }
                    }
                }

                Section("settings.apiKey".loc) {
                    SecureField("sk-…", text: $key)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !key.isEmpty {
                        Text("\(key.prefix(4))••••\(key.suffix(3))")
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        key = ""
                        settings.setAPIKey("", for: provider)
                    } label: { Text("ai.removeKey".loc) }
                        .disabled(key.isEmpty && !settings.hasKey(provider))
                }

                if provider == .custom {
                    Section("settings.baseURL".loc) {
                        TextField("https://…/v1", text: $baseURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                }

                Section("settings.model".loc) {
                    TextField(provider.defaultModel, text: $model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        loadModels()
                    } label: {
                        HStack {
                            Label("ai.fetchModels".loc, systemImage: "arrow.triangle.2.circlepath")
                            if loadingModels { Spacer(); ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(loadingModels || (key.isEmpty && provider != .custom))

                    ForEach(displayedModels) { option in
                        Button {
                            model = option.name
                            settings.haptic()
                        } label: {
                            HStack {
                                Text(option.name).font(.caption).lineLimit(1)
                                if option.isFree {
                                    Text("ai.freeBadge".loc)
                                        .font(.caption2.bold()).foregroundStyle(.green)
                                }
                                Spacer()
                                if model == option.name {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Button {
                        save()
                        test()
                    } label: {
                        HStack {
                            Label("settings.test".loc, systemImage: "bolt.horizontal.circle")
                            if testing { Spacer(); ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(testing || (key.isEmpty && provider != .custom))

                    if let testOK {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(testOK ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(testOK ? "ai.testOK".loc : "ai.testFail".loc).font(.caption.bold())
                                Text(testMessage).font(.caption2).foregroundStyle(.secondary)
                                if testOK && elapsed > 0 {
                                    Text(String(format: "%.2fs", elapsed))
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        save()
                        settings.aiProvider = provider
                        settings.haptic(.medium)
                        dismiss()
                    } label: {
                        Label("ai.makePrimary".loc, systemImage: "star")
                    }
                }
            }
            .navigationTitle(provider.display)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel".loc) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("settings.save".loc) { save(); dismiss() }.fontWeight(.semibold)
                }
            }
            .onAppear {
                key = settings.apiKey(for: provider)
                model = settings.model(for: provider)
                baseURL = settings.baseURL(for: provider)
                models = provider.suggestedModels.map { AIModelOption(name: $0, isFree: provider.isFree) }
            }
        }
    }

    private var displayedModels: [AIModelOption] {
        Array(models.prefix(40))
    }

    private func save() {
        settings.setAPIKey(key, for: provider)
        settings.setModel(model.isEmpty ? provider.defaultModel : model, for: provider)
        if provider == .custom { settings.setBaseURL(baseURL, for: provider) }
    }

    private func loadModels() {
        loadingModels = true
        let p = provider
        let base = provider == .custom ? baseURL : settings.baseURL(for: provider)
        let apiKey = key
        Task {
            do {
                let list = try await AIModelDirectory.fetch(provider: p, baseURL: base, apiKey: apiKey)
                await MainActor.run {
                    models = list.isEmpty
                        ? p.suggestedModels.map { AIModelOption(name: $0, isFree: p.isFree) }
                        : list
                    loadingModels = false
                }
            } catch {
                await MainActor.run {
                    testOK = false
                    testMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    loadingModels = false
                }
            }
        }
    }

    private func test() {
        testing = true
        testOK = nil
        var config = settings.config(for: provider)
        config.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = model.isEmpty ? provider.defaultModel : model
        if provider == .custom { config.baseURL = baseURL }
        let client = AIClient(config: config)
        let start = Date()
        Task {
            do {
                let reply = try await client.complete(
                    system: "You are a connectivity check. Reply with exactly: ready",
                    user: "ping", jsonMode: false)
                await MainActor.run {
                    elapsed = Date().timeIntervalSince(start)
                    testOK = true
                    testMessage = String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                    testing = false
                    settings.haptic(.medium)
                }
            } catch {
                await MainActor.run {
                    testOK = false
                    testMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    testing = false
                }
            }
        }
    }
}
