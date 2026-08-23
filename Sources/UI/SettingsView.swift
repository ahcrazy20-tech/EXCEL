import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: Library
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
                }

                Section {
                    Picker("files.headerMode".loc, selection: Binding(
                        get: { settings.headerMode },
                        set: { settings.headerMode = $0 })) {
                        ForEach(HeaderMode.allCases) { mode in
                            Text(mode.display).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("files.headerMode".loc)
                } footer: {
                    Text("files.headerMode.hint".loc).font(.caption2)
                }

                Section {
                    Toggle("settings.importColors".loc, isOn: $settings.importColors)
                    Toggle("settings.showColors".loc, isOn: $settings.showColors)
                } header: {
                    Text("settings.cellColors".loc)
                } footer: {
                    Text(settings.language == .ar
                         ? "الألوان تُستورد من ملفات Excel وتُعرض داخل الجدول. يعاد الاستيراد لتطبيق تغيير الاستيراد."
                         : "Colors are imported from Excel files and shown inside the grid. Re-import to apply import changes.")
                        .font(.caption2)
                }

                Section {
                    NavigationLink {
                        AIProvidersView()
                    } label: {
                        HStack {
                            Label("settings.ai".loc, systemImage: "sparkles")
                            Spacer()
                            if settings.hasAI {
                                Text(settings.aiProvider.display)
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("ai.none".loc).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    if settings.hasAI {
                        HStack {
                            Text("ai.active".loc).font(.caption)
                            Spacer()
                            Text(settings.configuredProviders.map { $0.display }.joined(separator: " → "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                } header: {
                    Text("settings.ai".loc)
                } footer: {
                    Text("ai.freeHint".loc).font(.caption2)
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

}
