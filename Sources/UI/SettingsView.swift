import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: Library
    @State private var apiKeyField = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.language".loc) {
                    Picker("settings.language".loc, selection: Binding(
                        get: { settings.language },
                        set: { settings.language = $0 })) {
                        ForEach(AppLanguage.allCases) { l in Text(l.display).tag(l) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("settings.appearance".loc) {
                    Picker("settings.appearance".loc, selection: $settings.themeRaw) {
                        Text("settings.theme.system".loc).tag("system")
                        Text("settings.theme.light".loc).tag("light")
                        Text("settings.theme.dark".loc).tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Toggle("settings.haptics".loc, isOn: $settings.haptics)
                }

                Section("settings.grid".loc) {
                    sliderRow("settings.rowHeight".loc, value: $settings.rowHeight, range: 26...58, step: 2)
                    sliderRow("settings.fontSize".loc, value: $settings.fontSize, range: 10...20, step: 1)
                    sliderRow("settings.colWidth".loc, value: $settings.columnWidth, range: 80...300, step: 10)
                    Toggle("files.headerRow".loc, isOn: $settings.headerRowDefault)
                }

                Section {
                    Picker("settings.provider".loc, selection: Binding(
                        get: { settings.aiProvider },
                        set: { settings.aiProvider = $0; apiKeyField = settings.apiKey })) {
                        ForEach(AIProvider.allCases) { p in Text(p.display).tag(p) }
                    }
                    TextField(settings.aiProvider.defaultModel, text: $settings.aiModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if settings.aiProvider == .custom {
                        TextField("settings.baseURL".loc, text: $settings.aiBaseURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    SecureField("settings.apiKey".loc, text: $apiKeyField)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack {
                        Button("settings.save".loc) {
                            settings.apiKey = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
                            settings.haptic()
                            testResult = "✓"
                        }
                        Spacer()
                        Button("settings.test".loc) { test() }
                            .disabled(apiKeyField.isEmpty || testing)
                    }
                    if testing { ProgressView() }
                    if let testResult {
                        Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                    }
                } header: {
                    Text("settings.ai".loc)
                } footer: {
                    Text("settings.aiNote".loc).font(.caption2)
                }

                Section("settings.storage".loc) {
                    HStack {
                        Text("settings.dbSize".loc)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: library.databaseSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("tab.files".loc)
                        Spacer()
                        Text("\(library.workbooks.count)").foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: { Text("settings.clearAll".loc) }
                }

                Section("settings.about".loc) {
                    HStack {
                        Text("app.name".loc)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                    Text(settings.language == .ar
                         ? "عارض ومحلل جداول ضخم يعمل بالكامل على جهازك. يدعم XLSX و CSV و JSON مع فهرسة SQLite للبحث الفوري."
                         : "A heavy-duty spreadsheet viewer and analyser that runs entirely on-device, backed by SQLite indexing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("settings.title".loc)
            .onAppear { apiKeyField = settings.apiKey }
            .alert("settings.clearAll".loc, isPresented: $confirmClear) {
                Button("common.delete".loc, role: .destructive) { library.deleteAll() }
                Button("common.cancel".loc, role: .cancel) {}
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(Int(value.wrappedValue))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func test() {
        testing = true
        testResult = nil
        var config = settings.aiConfig
        config.apiKey = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = AIClient(config: config)
        Task {
            do {
                let reply = try await client.complete(system: "Reply with the single word: ready",
                                                      user: "ping", jsonMode: false)
                await MainActor.run {
                    testResult = "✓ " + String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    testing = false
                }
            }
        }
    }
}
