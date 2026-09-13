import SwiftUI

/// Both axes scroll inside a clipped viewport. Row/column pagination bounds view
/// creation; fixed cell sizes and short previews prevent intrinsic-width explosions.
struct ResultTableView: View {
    let table: ResultTable
    var pageSize = 12
    var viewportHeight: CGFloat = 240
    @State private var rowPage = 0
    @State private var columnPage = 0
    @State private var selectedCell: ResultCellDetail?

    private var window: ResultPageWindow {
        ResultPageWindow(rows: table.rows.count, columns: table.columns.count,
                         rowPage: rowPage, columnPage: columnPage, pageSize: pageSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            pager(title: "result.rows".loc, range: window.rowRange, total: table.rows.count,
                  page: window.rowPage, count: window.rowPageCount, id: "rows") { rowPage = $0 }
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text("#").font(.caption.bold()).frame(width: 52, height: 44)
                            ForEach(Array(window.columnRange), id: \.self) { column in
                                Text(String(table.columns[column].prefix(160)))
                                    .font(.caption.bold()).lineLimit(2)
                                    .padding(.horizontal, 8).frame(width: 144, height: 44, alignment: .leading)
                            }
                        }
                        .background(Color.accentColor.opacity(0.14))
                        ForEach(Array(window.rowRange), id: \.self) { row in
                            HStack(spacing: 0) {
                                Text(String(row + 1)).font(.caption.monospacedDigit())
                                    .frame(width: 52, height: 44)
                                ForEach(Array(window.columnRange), id: \.self) { column in
                                    cell(row: row, column: column)
                                }
                            }
                            .background(row.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.07))
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .clipped()
                .accessibilityIdentifier("result.viewport")
            }
            .frame(height: viewportHeight)
            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            pager(title: "result.columns".loc, range: window.columnRange, total: table.columns.count,
                  page: window.columnPage, count: window.columnPageCount, id: "columns") { columnPage = $0 }
            Text("result.navigationHint".loc).font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(item: $selectedCell) { cell in
            LongTextView(title: cell.title, text: cell.text)
        }
    }

    private func cell(row: Int, column: Int) -> some View {
        let value = column < table.rows[row].count ? table.rows[row][column] : .null
        return Button {
            selectedCell = ResultCellDetail(title: "\(table.columns[column]) · \(row + 1)", text: value.stringValue)
        } label: {
            Text(preview(value)).font(.caption.monospacedDigit()).lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8).frame(width: 144, height: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(String(table.columns[column].prefix(160))), \("sheet.row".loc) \(row + 1): \(preview(value))")
        .accessibilityIdentifier("result.cell.\(row).\(column)")
    }

    private func preview(_ value: DBValue) -> String {
        switch value {
        case .double(let value): return ReportBuilder.formatNumber(value)
        default: return String(value.stringValue.prefix(160))
        }
    }

    private func pager(title: String, range: Range<Int>, total: Int, page: Int, count: Int,
                       id: String, select: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "result.range".loc, title, range.isEmpty ? 0 : range.lowerBound + 1, range.upperBound, total))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { select(page - 1) } label: {
                    Image(systemName: "chevron.backward").frame(minWidth: 44, minHeight: 36)
                }.disabled(page == 0)
                    .accessibilityLabel("result.previous".loc + " " + title)
                    .accessibilityIdentifier("result.\(id).previous")
                Spacer()
                Text(String(format: "result.page".loc, page + 1, count)).font(.caption.monospacedDigit())
                Spacer()
                Button { select(page + 1) } label: {
                    Image(systemName: "chevron.forward").frame(minWidth: 44, minHeight: 36)
                }.disabled(page + 1 >= count)
                    .accessibilityLabel("result.next".loc + " " + title)
                    .accessibilityIdentifier("result.\(id).next")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct ResultCellDetail: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct ResultExplorerView: View {
    let table: ResultTable
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if table.truncated {
                            Text("analysis.truncated".loc).font(.caption).foregroundStyle(.orange)
                        }
                        ResultTableView(table: table, pageSize: 20,
                                        viewportHeight: max(160, geometry.size.height * 0.5))
                    }
                    .padding()
                }
            }
            .navigationTitle("ask.result".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".loc) { dismiss() }.accessibilityIdentifier("result.close")
                }
            }
        }
    }
}

/// Long responses/cells never create one enormous Text layout in the Ask screen.
struct LongTextView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [String] = []
    @State private var page = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                if pages.isEmpty { ProgressView().padding() }
                else {
                    Text(verbatim: pages[min(page, pages.count - 1)])
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding()
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("result.previous".loc) { page -= 1 }.disabled(page == 0)
                    Spacer()
                    Text(String(format: "result.page".loc, page + 1, max(1, pages.count))).font(.caption)
                    Spacer()
                    Button("result.next".loc) { page += 1 }.disabled(page + 1 >= pages.count)
                }
                .padding().background(.regularMaterial)
            }
            .navigationTitle(String(title.prefix(100)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".loc) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("result.copyFull".loc) { UIPasteboard.general.string = text }
                }
            }
            .task {
                let chunks = await Task.detached(priority: .userInitiated) { TextPages.split(text) }.value
                guard !Task.isCancelled else { return }
                pages = chunks
            }
        }
    }
}
