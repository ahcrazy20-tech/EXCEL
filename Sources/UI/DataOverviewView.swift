import SwiftUI

struct DataOverviewView: View {
    @ObservedObject var vm: SheetViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var overview: DataOverview?
    @State private var loading = false
    @State private var progress = 0
    @State private var filtered = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(vm.sheet.name, systemImage: "tablecells").font(.headline)
                    Text(filtered ? "overview.filtered".loc : "overview.allRows".loc)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("overview.local".loc).font(.caption2).foregroundStyle(.secondary)
                }
                if loading {
                    Section {
                        ProgressView(value: Double(progress), total: Double(max(1, vm.sheet.columns.count)))
                        Text(String(format: "overview.progress".loc, progress, vm.sheet.columns.count))
                            .font(.caption)
                        Button("common.cancel".loc) { cancel() }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if let overview {
                    summary(overview)
                    ForEach(overview.columns) { column in
                        profile(column)
                    }
                }
            }
            .navigationTitle("overview.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".loc) { cancel(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { load() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("overview.refresh".loc).disabled(loading)
                }
            }
        }
        .onAppear { if overview == nil { load() } }
        .onDisappear { cancel(showMessage: false) }
    }

    private func summary(_ overview: DataOverview) -> some View {
        Section {
            metric("overview.matchingRows".loc, ReportBuilder.formatInt(overview.matchingRows))
            metric("overview.profiledRows".loc, ReportBuilder.formatInt(overview.sampledRows))
            metric("sheet.columns".loc, String(overview.columns.count))
            if let completeness = overview.completeness {
                metric("overview.completeness".loc, String(format: "%.1f%%", completeness * 100))
                ProgressView(value: completeness).tint(completeness >= 0.95 ? .green : .orange)
            }
            if overview.matchingRows == 0 { Text("sheet.noResults".loc).foregroundStyle(.secondary) }
            Label(overview.isSampled ? "overview.sampled".loc : "overview.exact".loc,
                  systemImage: overview.isSampled ? "info.circle" : "checkmark.seal")
                .font(.caption).foregroundStyle(overview.isSampled ? Color.orange : Color.green)
        } header: {
            Text("overview.quality".loc)
        } footer: {
            Text("overview.sampleNote".loc)
        }
    }

    private func profile(_ profile: OverviewColumn) -> some View {
        Section {
            metric("overview.missing".loc, ReportBuilder.formatInt(profile.missing))
            metric("overview.distinct".loc, ReportBuilder.formatInt(profile.distinct))
            if profile.column.kind == .number {
                if let average = profile.average { metric("overview.average".loc, ReportBuilder.formatNumber(average)) }
                if let minimum = profile.minimum { metric("overview.minimum".loc, ReportBuilder.formatNumber(minimum)) }
                if let maximum = profile.maximum { metric("overview.maximum".loc, ReportBuilder.formatNumber(maximum)) }
                if profile.invalidNumbers > 0 {
                    Label(String(format: "overview.invalidNumbers".loc, profile.invalidNumbers),
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Button {
                vm.apply(query: QuerySpec(filters: [FilterCondition(columnIndex: profile.column.index, op: .isEmpty)]))
                dismiss()
            } label: { Label("overview.showMissing".loc, systemImage: "line.3.horizontal.decrease.circle") }
        } header: {
            Label(profile.column.name, systemImage: profile.column.kind.symbol)
        } footer: {
            Text("overview.missingScope".loc)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
        }
    }

    private func cancel(showMessage: Bool = true) {
        generation = UUID()
        task?.cancel()
        task = nil
        if loading && showMessage { error = "analysis.cancelled".loc }
        loading = false
    }

    private func load() {
        cancel(showMessage: false)
        let id = generation
        loading = true
        progress = 0
        error = nil
        let sheet = vm.sheet
        let path = vm.engine.db.path
        let query = vm.query
        filtered = !query.search.isEmpty || !query.filters.isEmpty
        task = Task { @MainActor in
            defer { if generation == id { loading = false; task = nil } }
            do {
                let result = try await AnalysisRunner.read(path: path, sheet: sheet) { engine in
                    try DataOverview.build(engine: engine, query: query) { done, _ in
                        Task { @MainActor in
                            if generation == id { progress = done }
                        }
                    }
                }
                try Task.checkCancellation()
                guard generation == id else { return }
                overview = result
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
