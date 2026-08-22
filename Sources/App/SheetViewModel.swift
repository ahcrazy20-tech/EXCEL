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
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hiddenColumns: Set<Int> = []
    @Published var columnWidths: [Int: CGFloat] = [:]
    @Published var selectedRow: [DBValue]?
    @Published var lastAnalysis: ResultTable?

    let pageSize = 200
    private var loadingPages = Set<Int>()
    private var generation = 0

    init(sheet: SheetInfo) {
        self.sheet = sheet
        self.engine = QueryEngine(db: Workspace.shared.db, sheet: sheet)
        self.totalRows = sheet.rowCount
        refresh()
    }

    var visibleColumns: [ColumnInfo] {
        sheet.columns.filter { !hiddenColumns.contains($0.index) }
    }

    func refresh() {
        generation += 1
        let gen = generation
        loadedPages.removeAll()
        loadingPages.removeAll()
        isLoading = true
        let spec = query
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            let count = (try? engine.countRows(spec)) ?? 0
            let first = (try? engine.fetchRows(spec, offset: 0, limit: 200)) ?? []
            await MainActor.run {
                guard gen == self.generation else { return }
                self.totalRows = count
                self.loadedPages[0] = first
                self.isLoading = false
            }
        }
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
        guard !loadingPages.contains(page), loadedPages[page] == nil, page >= 0 else { return }
        loadingPages.insert(page)
        let gen = generation
        let spec = query
        let engine = self.engine
        let offset = page * pageSize
        let limit = pageSize
        Task.detached(priority: .userInitiated) {
            let rows = (try? engine.fetchRows(spec, offset: offset, limit: limit)) ?? []
            await MainActor.run {
                guard gen == self.generation else { return }
                self.loadedPages[page] = rows
                self.loadingPages.remove(page)
                // Keep memory bounded: drop pages far from the one just loaded.
                if self.loadedPages.count > 24 {
                    let keep = Set((page - 4)...(page + 4))
                    for k in self.loadedPages.keys where !keep.contains(k) {
                        self.loadedPages.removeValue(forKey: k)
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
