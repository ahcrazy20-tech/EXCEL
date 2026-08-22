import SwiftUI
import Charts

// MARK: - Stats overview

struct StatsView: View {
    @ObservedObject var vm: SheetViewModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    @State private var stats: [QueryEngine.ColumnStats] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("\(ReportBuilder.formatInt(vm.totalRows))", systemImage: "list.number")
                        Spacer()
                        Label("\(vm.sheet.columns.count)", systemImage: "tablecells")
                    }
                    .font(.subheadline.bold())
                }
                if loading {
                    HStack { ProgressView(); Text("common.loading".loc) }
                }
                ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: s.kind.symbol).foregroundStyle(.tint)
                            Text(s.name).font(.headline)
                            Spacer()
                            Text(s.kind.rawValue).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        let filledRatio = s.total > 0 ? Double(s.nonEmpty) / Double(s.total) : 0
                        ProgressView(value: filledRatio)
                            .tint(filledRatio > 0.9 ? .green : (filledRatio > 0.6 ? .orange : .red))
                        HStack(spacing: 12) {
                            Text("\(ReportBuilder.formatInt(s.nonEmpty)) filled").font(.caption2)
                            Text("\(ReportBuilder.formatInt(s.distinct)) distinct").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        if s.kind == .number {
                            HStack(spacing: 14) {
                                if let v = s.sum { metric("Σ", ReportBuilder.formatNumber(v)) }
                                if let v = s.avg { metric("x̄", ReportBuilder.formatNumber(v)) }
                                if let v = s.median { metric("M", ReportBuilder.formatNumber(v)) }
                            }
                            HStack(spacing: 14) {
                                if let v = s.min { metric("min", v.stringValue) }
                                if let v = s.max { metric("max", v.stringValue) }
                            }
                        } else if !s.topValues.isEmpty {
                            Text(s.topValues.prefix(3).map { "\($0.0) (\($0.1))" }.joined(separator: " • "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("sheet.stats".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("common.close".loc) { dismiss() } } }
            .task { await load() }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func load() async {
        let engine = vm.engine
        let query = vm.query
        let indices = vm.sheet.columns.map { $0.index }
        let result = await Task.detached(priority: .userInitiated) { () -> [QueryEngine.ColumnStats] in
            indices.compactMap { try? engine.stats(for: $0, query: query, includeTop: true) }
        }.value
        stats = result
        loading = false
    }
}

// MARK: - Charts

struct ChartPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
}

struct ChartsView: View {
    @ObservedObject var vm: SheetViewModel
    @Environment(\.dismiss) var dismiss

    @State private var groupColumn: Int = 0
    @State private var valueColumn: Int?
    @State private var function: AggFunction = .count
    @State private var chartType = 0
    @State private var points: [ChartPoint] = []
    @State private var loading = false
    @State private var limit = 12

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                chartArea
            }
            .navigationTitle("sheet.chart".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("common.close".loc) { dismiss() } } }
            .onAppear(perform: initialSetup)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("", selection: $chartType) {
                Image(systemName: "chart.bar.fill").tag(0)
                Image(systemName: "chart.pie.fill").tag(1)
                Image(systemName: "chart.line.uptrend.xyaxis").tag(2)
            }
            .pickerStyle(.segmented)

            HStack {
                Picker("common.column".loc, selection: $groupColumn) {
                    ForEach(vm.sheet.columns) { c in Text(c.name).tag(c.index) }
                }
                Picker("", selection: $function) {
                    ForEach(AggFunction.allCases.filter { $0 != .stdev }) { f in Text(f.display).tag(f) }
                }
                .labelsHidden()
            }
            if function.needsColumn {
                Picker("Value", selection: Binding(get: { valueColumn ?? -1 }, set: { valueColumn = $0 })) {
                    Text("—").tag(-1)
                    ForEach(vm.sheet.columns.filter { $0.kind == .number }) { c in Text(c.name).tag(c.index) }
                }
            }
            Stepper("Top \(limit)", value: $limit, in: 3...30)
                .font(.caption)
        }
        .padding(12)
        .onChange(of: groupColumn) { _ in reload() }
        .onChange(of: valueColumn) { _ in reload() }
        .onChange(of: function) { _ in reload() }
        .onChange(of: limit) { _ in reload() }
    }

    @ViewBuilder
    private var chartArea: some View {
        if loading {
            Spacer(); ProgressView(); Spacer()
        } else if points.isEmpty {
            Spacer(); Text("sheet.noResults".loc).foregroundStyle(.secondary); Spacer()
        } else {
            ScrollView {
                Group {
                    switch chartType {
                    case 1:
                        PieChartView(points: points)
                            .frame(height: 320)
                    case 2:
                        Chart(points) { p in
                            LineMark(x: .value("k", p.label), y: .value("v", p.value))
                            PointMark(x: .value("k", p.label), y: .value("v", p.value))
                        }
                        .frame(height: 300)
                    default:
                        Chart(points) { p in
                            BarMark(x: .value("v", p.value), y: .value("k", p.label))
                                .foregroundStyle(by: .value("k", p.label))
                                .cornerRadius(4)
                        }
                        .frame(height: CGFloat(max(220, points.count * 30)))
                    }
                }
                .padding()

                VStack(spacing: 4) {
                    ForEach(points) { p in
                        HStack {
                            Text(p.label).lineLimit(1).font(.caption)
                            Spacer()
                            Text(ReportBuilder.formatNumber(p.value)).font(.caption.monospacedDigit())
                        }
                        Divider()
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func initialSetup() {
        if let firstText = vm.sheet.columns.first(where: { $0.kind == .text || $0.kind == .boolean }) {
            groupColumn = firstText.index
        } else if let f = vm.sheet.columns.first {
            groupColumn = f.index
        }
        if let n = vm.sheet.columns.first(where: { $0.kind == .number }) {
            valueColumn = n.index
            function = .sum
        }
        reload()
    }

    private func reload() {
        loading = true
        var measure: Int?
        if let v = valueColumn, v >= 0 { measure = v }
        var aggregation = Aggregation(function: function, columnIndex: function.needsColumn ? measure : nil)
        if function.needsColumn && measure == nil {
            aggregation = Aggregation(function: .count, columnIndex: nil)
        }
        let spec = AnalysisSpec(query: vm.query, groupBy: [groupColumn], aggregations: [aggregation],
                                sortByResultColumn: 1, sortDescending: true, limit: limit)
        let engine = vm.engine
        Task.detached(priority: .userInitiated) {
            let table = (try? engine.runAnalysis(spec)) ?? ResultTable(columns: [], rows: [])
            let pts: [ChartPoint] = table.rows.compactMap { row in
                guard row.count >= 2 else { return nil }
                let label = row[0].stringValue.isEmpty ? "—" : row[0].stringValue
                return ChartPoint(label: String(label.prefix(28)), value: row[1].doubleValue ?? 0)
            }
            await MainActor.run {
                points = pts
                loading = false
            }
        }
    }
}

// MARK: - Export

struct ExportView: View {
    @ObservedObject var vm: SheetViewModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    @State private var format: ExportFormat = .csv
    @State private var onlyFiltered = true
    @State private var maxRows = 100_000
    @State private var working = false
    @State private var shareItem: ShareItem?
    @State private var progress: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("sheet.export".loc) {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { f in Text(f.display).tag(f) }
                    }
                    Toggle("Apply current filters", isOn: $onlyFiltered)
                    if format != .csv {
                        Stepper("Max rows: \(ReportBuilder.formatInt(maxRows))", value: $maxRows, in: 1000...500_000, step: 1000)
                    }
                }
                Section {
                    Button {
                        export()
                    } label: {
                        HStack {
                            if working { ProgressView().controlSize(.small) }
                            Text(working ? "common.loading".loc : "common.share".loc)
                        }
                    }
                    .disabled(working)
                    if working && progress > 0 {
                        ProgressView(value: progress)
                    }
                }
                Section {
                    Text("CSV exports stream directly to disk and support the full sheet; other formats are capped for memory safety.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("sheet.export".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel".loc) { dismiss() } } }
            .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        }
    }

    private func export() {
        working = true
        progress = 0
        let engine = vm.engine
        let query = onlyFiltered ? vm.query : QuerySpec()
        let name = vm.sheet.name
        let fmt = format
        let cap = maxRows
        let arabic = settings.language == .ar

        Task.detached(priority: .userInitiated) {
            do {
                let url: URL
                switch fmt {
                case .csv:
                    url = try Exporter.csvStreaming(engine: engine, query: query, name: name) { p in
                        Task { @MainActor in progress = p }
                    }
                case .xlsx, .json:
                    let rows = try engine.fetchRows(query, offset: 0, limit: cap)
                    let table = ResultTable(columns: engine.sheet.columns.map { $0.name },
                                            rows: rows.map { Array($0.dropFirst()) })
                    url = fmt == .xlsx
                        ? try Exporter.xlsx(table: table, name: name)
                        : try Exporter.json(table: table, name: name)
                case .markdown, .html, .pdf:
                    let builder = ReportBuilder(engine: engine, arabic: arabic)
                    let md = try builder.fullReport(query: query)
                    if fmt == .markdown {
                        url = try Exporter.text(md, name: name, ext: "md")
                    } else {
                        let html = MarkdownRenderer.html(from: md, rtl: arabic)
                        if fmt == .html {
                            url = try Exporter.text(html, name: name, ext: "html")
                        } else {
                            url = try await MainActor.run { try Exporter.pdf(html: html, name: name) }
                        }
                    }
                }
                await MainActor.run {
                    working = false
                    shareItem = ShareItem(url: url)
                }
            } catch {
                await MainActor.run {
                    working = false
                    Library.shared.errorMessage = error.localizedDescription
                }
            }
        }
    }
}


// MARK: - Pie chart (iOS 16 compatible, drawn with paths)

struct PieChartView: View {
    let points: [ChartPoint]

    private var total: Double { max(0.000001, points.reduce(0) { $0 + max(0, $1.value) }) }

    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal,
                                           .indigo, .mint, .red, .cyan, .yellow, .brown]

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                ZStack {
                    ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                        Path { path in
                            let center = CGPoint(x: size / 2, y: size / 2)
                            path.move(to: center)
                            path.addArc(center: center, radius: size / 2,
                                        startAngle: .degrees(slice.start - 90),
                                        endAngle: .degrees(slice.end - 90), clockwise: false)
                            path.closeSubpath()
                        }
                        .fill(PieChartView.palette[index % PieChartView.palette.count])
                    }
                    Circle()
                        .fill(Color(uiColor: .systemBackground))
                        .frame(width: size * 0.5, height: size * 0.5)
                }
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 200, height: 200)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(points.prefix(10).enumerated()), id: \.offset) { index, p in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(PieChartView.palette[index % PieChartView.palette.count])
                            .frame(width: 9, height: 9)
                        Text(p.label).font(.caption2).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(String(format: "%.0f%%", p.value / total * 100))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private struct Slice { let start: Double; let end: Double }

    private var slices: [Slice] {
        var result: [Slice] = []
        var angle = 0.0
        for p in points {
            let sweep = max(0, p.value) / total * 360
            result.append(Slice(start: angle, end: angle + sweep))
            angle += sweep
        }
        return result
    }
}
