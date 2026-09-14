import Foundation

struct TrashedSheet: Identifiable {
    /// Each trip to Trash has a new token. A stale confirmation cannot purge a later trip.
    let id: String
    let sheetID: Int64
    let workbookID: Int64
    let name: String
    let workbookName: String
    let rowCount: Int
    let deletedAt: Date
}

enum TrashError: LocalizedError {
    case stale, unavailable, damaged
    var errorDescription: String? {
        switch self {
        case .stale: return "trash.stale".loc
        case .unavailable: return "trash.restoreFirst".loc
        case .damaged: return "trash.damaged".loc
        }
    }
}

extension Workspace {
    /// Soft deletion is metadata-only. Data tables, fills, reports, recipes, dashboards,
    /// IDs and layout preferences are retained until an explicit permanent deletion.
    @discardableResult
    func trashSheet(_ id: Int64, workbookID: Int64) throws -> [Int64] {
        try db.transaction {
            let rows = try db.query("SELECT workbook_id,table_name FROM meta_sheets WHERE id=?", [.int(id)])
            guard let row = rows.first, row[0] == .int(workbookID) else { throw TrashError.stale }
            guard row[1] == .text("data_\(id)") else { throw TrashError.damaged }
            try markTrashed(id)
            return [id]
        }
    }

    @discardableResult
    func trashWorkbook(_ id: Int64) throws -> [Int64] {
        try db.transaction {
            let rows = try db.query("SELECT id,table_name FROM meta_sheets WHERE workbook_id=? AND id NOT IN (SELECT sheet_id FROM meta_sheet_trash)", [.int(id)])
            return try trashRows(rows)
        }
    }

    /// One transaction across all active sheets; never an asynchronous loop that
    /// could interleave with a new import. Existing Trash entries keep their tokens/dates.
    @discardableResult
    func trashAllSheets() throws -> [Int64] {
        try db.transaction {
            try trashRows(db.query("SELECT id,table_name FROM meta_sheets WHERE id NOT IN (SELECT sheet_id FROM meta_sheet_trash)"))
        }
    }

    private func trashRows(_ rows: [[DBValue]]) throws -> [Int64] {
        var ids: [Int64] = []
        for row in rows {
            guard case .int(let id) = row[0], row[1] == .text("data_\(id)") else { throw TrashError.damaged }
            try markTrashed(id)
            ids.append(id)
        }
        return ids
    }

    private func markTrashed(_ id: Int64) throws {
        try db.run("INSERT OR IGNORE INTO meta_sheet_trash(sheet_id,token,deleted_at) VALUES(?,?,?)",
                   [.int(id), .text(UUID().uuidString), .double(Date().timeIntervalSince1970)])
    }

    func trashCount() throws -> Int {
        Int(try db.scalar("SELECT COUNT(*) FROM meta_sheet_trash").doubleValue ?? 0)
    }

    func loadTrash(offset: Int = 0, limit: Int = 50) throws -> [TrashedSheet] {
        let rows = try db.query("""
            SELECT t.token,s.id,s.workbook_id,s.name,w.name,s.row_count,t.deleted_at
            FROM meta_sheet_trash t JOIN meta_sheets s ON s.id=t.sheet_id
            JOIN meta_workbooks w ON w.id=s.workbook_id
            ORDER BY t.deleted_at DESC,t.sheet_id DESC LIMIT ? OFFSET ?
            """, [.int(Int64(max(1, min(limit, 100)))), .int(Int64(max(0, offset)))])
        return try rows.map { row in
            guard case .int(let sheetID) = row[1], case .int(let workbookID) = row[2],
                  case .int(let rowCount) = row[5], rowCount >= 0,
                  let date = row[6].doubleValue, date.isFinite else { throw TrashError.damaged }
            return TrashedSheet(id: row[0].stringValue, sheetID: sheetID,
                                workbookID: workbookID, name: row[3].stringValue,
                                workbookName: row[4].stringValue, rowCount: Int(rowCount),
                                deletedAt: Date(timeIntervalSince1970: date))
        }
    }

    func restoreSheet(_ entry: TrashedSheet) throws {
        try db.transaction {
            try validateTrashEntry(entry)
            guard try db.scalar("SELECT type FROM sqlite_master WHERE name=?", [.text("data_\(entry.sheetID)")]) == .text("table") else {
                throw TrashError.damaged
            }
            try db.run("DELETE FROM meta_sheet_trash WHERE sheet_id=? AND token=?", [.int(entry.sheetID), .text(entry.id)])
        }
    }

    /// Only Trash entries can be purged through this user-facing API. All data and
    /// metadata deletion is atomic, including removal of the final workbook record.
    func permanentlyDelete(_ entry: TrashedSheet) throws {
        try db.transaction {
            try validateTrashEntry(entry)
            try deleteSheetContents(id: entry.sheetID, tableName: "data_\(entry.sheetID)")
            try db.run("DELETE FROM meta_workbooks WHERE id=? AND NOT EXISTS (SELECT 1 FROM meta_sheets WHERE workbook_id=?)",
                       [.int(entry.workbookID), .int(entry.workbookID)])
        }
    }

    private func validateTrashEntry(_ entry: TrashedSheet) throws {
        let rows = try db.query("""
            SELECT s.workbook_id,s.table_name FROM meta_sheet_trash t
            JOIN meta_sheets s ON s.id=t.sheet_id JOIN meta_workbooks w ON w.id=s.workbook_id
            WHERE t.sheet_id=? AND t.token=?
            """, [.int(entry.sheetID), .text(entry.id)])
        guard let row = rows.first, row[0] == .int(entry.workbookID) else { throw TrashError.stale }
        guard row[1] == .text("data_\(entry.sheetID)") else { throw TrashError.damaged }
    }
}
