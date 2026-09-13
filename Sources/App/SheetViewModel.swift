import Foundation
import SwiftUI

/// Paged, cancellable data source for a single sheet. Only visible pages live in memory.
@MainActor
final class SheetViewModel: ObservableObject {
    let sheet: SheetInfo
    let engine: QueryEngine

    @Published var query = QuerySpec()
    @Published var totalRows = 0
    @Published var loadedPages: [Int: [[DBValue]]] = [:]   // page -> rows (first element is rowid)
    /// page -> row offset within page -> (column index -> fill ARGB)
    @Published var pageFills: [Int: [Int: [Int: UInt32]]] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hiddenColumns: Set<Int> = [] {
        didSet { persistLayout() }
    }
    @Published var columnWidths: [Int: CGFloat] = [:] {
        didSet { persistLayout() }
    }
    @Published var selectedRow: [DBValue]?
    @Published var lastAnalysis: ResultTable?

    let pageSize = 200
    private var loadingPages = Set<Int>()
    private var generation = 0
    private var active = true

    init(sheet: SheetInfo, database: Database = Workspace.shared.db) {
        self.sheet = sheet
        self.engine = QueryEngine(db: database, sheet: sheet)
        self.totalRows = sheet.rowCount
        loadLayout()
        refresh()
    }

    // MARK: Per-sheet layout persistence (column widths + hidden columns)

    private static let layoutKey = "sheetLayouts"

    static func removeLayouts(for sheetIDs: Set<Int64>, defaults: UserDefaults = .standard) {
        var layouts = defaults.dictionary(forKey: layoutKey) ?? [:]
        for id in sheetIDs { layouts.removeValue(forKey: String(id)) }
        defaults.set(layouts, forKey: layoutKey)
    }

    private func loadLayout() {
        guard let all = UserDefaults.standard.dictionary(forKey: Self.layoutKey),
              let entry = all["\(sheet.id)"] as? [String: Any] else { return }
        if let widths = entry["widths"] as? [String: Double] {
            for (k, v) in widths {
                if let idx = Int(k) { columnWidths[idx] = CGFloat(v) }
            }
        }
        if let hidden = entry["hidden"] as? [Int] {
            hiddenColumns = Set(hidden)
        }
    }

    private func persistLayout() {
        let widths = columnWidths.reduce(into: [String: Double]()) { dict, pair in
            dict["\(pair.key)"] = Double(pair.value)
        }
        var all = UserDefaults.standard.dictionary(forKey: Self.layoutKey) ?? [:]
        all["\(sheet.id)"] = ["widths": widths, "hidden": Array(hiddenColumns)] as [String: Any]
        UserDefaults.standard.set(all, forKey: Self.layoutKey)
    }

    var visibleColumns: [ColumnInfo] {
        sheet.columns.filter { !hiddenColumns.contains($0.index) }
    }

    var colorsEnabled: Bool {
        sheet.hasColors && AppSettings.shared.showCellColors
    }

    /// Fill colours for a row, keyed by column index (nil when the page/row has none).
    func fills(page: Int, offset: Int) -> [Int: UInt32]? {
        pageFills[page]?[offset]
    }

    /// Fetches one page of rows plus its fill colours off the main thread.
    private nonisolated static func loadPage(engine: QueryEngine, spec: QuerySpec,
                                            offset: Int, limit: Int, colors: Bool)
    -> ([[DBValue]], [Int: [Int: UInt32]]) {
        guard let rows = try? engine.fetchRows(spec, offset: offset, limit: limit) else {
            return ([], [:])
        }
        guard colors, !rows.isEmpty else { return (rows, [:]) }
        let raw = (try? engine.fetchFills(rowids: rows.map { row -> Int64? in
            guard case .int(let id) = row.first else { return nil }
            return id
        }.compactMap { $0 })) ?? [:]
        guard !raw.isEmpty else { return (rows, [:]) }
        var decoded: [Int: [Int: UInt32]] = [:]
        for (i, row) in rows.enumerated() {
            guard case .int(let id) = row.first, let stored = raw[id] else { continue }
            let fills = FillCodec.decode(stored)
            if !fills.isEmpty { decoded[i] = fills }
        }
        return (rows, decoded)
    }

    func refresh() {
        active = true
        generation += 1
        let gen = generation
        loadedPages.removeAll()
        pageFills.removeAll()
        loadingPages.removeAll()
        isLoading = true
        let spec = query
        let engine = self.engine
        let colors = colorsEnabled
        Task.detached(priority: .userInitiated) {
            let count = (try? engine.countRows(spec)) ?? 0
            let (rows, pageFill) = SheetViewModel.loadPage(engine: engine, spec: spec,
                                                           offset: 0, limit: 200, colors: colors)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.totalRows = count
                self.loadedPages[0] = rows
                self.pageFills[0] = pageFill
                self.isLoading = false
            }
        }
    }

    func suspend() {
        active = false
        generation += 1
        loadingPages.removeAll()
        loadedPages.removeAll()
        pageFills.removeAll()
        isLoading = false
    }

    func row(at index: Int) -> [DBValue]? {
        let page = index / pageSize
        guard let rows = loadedPages[page] else {
            requestPage(page)
            return nil
        }
        let offset = index % pageSize
        return offset < rows.count ? rows[offset] : nil
    }

    func requestPage(_ page: Int) {
        guard active, !loadingPages.contains(page), loadedPages[page] == nil, page >= 0 else { return }
        loadingPages.insert(page)
        let gen = generation
        let spec = query
        let engine = self.engine
        let colors = colorsEnabled
        let offset = page * pageSize
        let limit = pageSize
        Task.detached(priority: .userInitiated) {
            let (rows, fills) = SheetViewModel.loadPage(engine: engine, spec: spec,
                                                        offset: offset, limit: limit, colors: colors)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.loadedPages[page] = rows
                self.pageFills[page] = fills
                self.loadingPages.remove(page)
                // Keep memory bounded: drop pages far from the one just loaded.
                if self.loadedPages.count > 24 {
                    let keep = Set((page - 4)...(page + 4))
                    for k in self.loadedPages.keys where !keep.contains(k) {
                        self.loadedPages.removeValue(forKey: k)
                        self.pageFills.removeValue(forKey: k)
                    }
                }
            }
        }
    }

    func prefetch(around index: Int) {
        let page = index / pageSize
        requestPage(page)
        requestPage(page + 1)
        if page > 0 { requestPage(page - 1) }
    }

    // MARK: Mutations

    func toggleSort(column: Int) {
        if let existing = query.sorts.first, existing.columnIndex == column {
            if existing.ascending {
                query.sorts = [SortSpec(columnIndex: column, ascending: false)]
            } else {
                query.sorts = []
            }
        } else {
            query.sorts = [SortSpec(columnIndex: column, ascending: true)]
        }
        engine.ensureIndex(columnIndex: column)
        refresh()
    }

    func setSearch(_ text: String) {
        guard query.search != text else { return }
        query.search = text
        refresh()
    }

    func apply(query newQuery: QuerySpec) {
        query = newQuery
        refresh()
    }

    func clearAll() {
        query = QuerySpec()
        refresh()
    }

    func width(for column: ColumnInfo, default def: CGFloat) -> CGFloat {
        columnWidths[column.index] ?? def
    }
}
