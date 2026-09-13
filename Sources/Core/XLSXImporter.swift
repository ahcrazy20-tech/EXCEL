import Foundation
import ZIPFoundation

// MARK: - Importer

final class XLSXImporter {
    private let workspace: Workspace
    private let cancelFlag: () -> Bool

    init(workspace: Workspace, cancelFlag: @escaping () -> Bool = { false }) {
        self.workspace = workspace
        self.cancelFlag = cancelFlag
    }

    /// Imports a .xlsx/.xlsm workbook. Returns the created workbook id.
    func importWorkbook(url: URL, headerMode: HeaderMode, importColors: Bool = true,
                        progress: @escaping (ImportProgress) -> Void) throws -> Int64 {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            throw ImportError.corrupt("not a valid xlsx container")
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheetx-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress(ImportProgress(stage: "reading workbook", fraction: 0.02, rowsDone: 0, sheetName: ""))

        // 1. workbook.xml + rels
        guard let wbData = try data(for: "xl/workbook.xml", in: archive) else {
            throw ImportError.corrupt("missing xl/workbook.xml")
        }
        let wbParser = WorkbookParser()
        let p1 = XMLParser(data: wbData); p1.delegate = wbParser; p1.parse()

        var rels: [String: String] = [:]
        if let relData = try data(for: "xl/_rels/workbook.xml.rels", in: archive) {
            let rp = RelsParser()
            let p = XMLParser(data: relData); p.delegate = rp; p.parse()
            rels = rp.map
        }

        // 2. shared strings (streamed via temp file to keep memory flat)
        progress(ImportProgress(stage: "loading shared strings", fraction: 0.06, rowsDone: 0, sheetName: ""))
        var sharedStrings: [String] = []
        if let sstURL = try extractToFile(entry: "xl/sharedStrings.xml", in: archive, dir: work) {
            let sp = SharedStringsParser()
            if let parser = XMLParser(contentsOf: sstURL) {
                parser.delegate = sp
                parser.parse()
            }
            sharedStrings = sp.strings
            try? FileManager.default.removeItem(at: sstURL)
        }

        // 3. styles (for date detection + cell fill colours)
        var themePalette: [UInt32] = XLSXColor.defaultTheme
        if importColors, let themeData = try data(for: "xl/theme/theme1.xml", in: archive) {
            let tp = ThemeParser()
            let p = XMLParser(data: themeData); p.delegate = tp; p.parse()
            if tp.scheme.count == 12 { themePalette = XLSXColor.themePalette(fromScheme: tp.scheme) }
        }
        var dateStyles: Set<Int> = []
        var fillColors: [Int: UInt32] = [:]
        if let stylesData = try data(for: "xl/styles.xml", in: archive) {
            let sp = StylesParser(themePalette: themePalette)
            let p = XMLParser(data: stylesData); p.delegate = sp; p.parse()
            dateStyles = sp.dateStyles
            fillColors = importColors ? sp.fillColors : [:]
        }

        // 4. workbook record
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let wbID = try workspace.createWorkbook(
            name: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            size: size)

        let sheets = wbParser.sheets
        var importedAnySheet = false

        for (i, sheetRef) in sheets.enumerated() {
            if cancelFlag() { throw ImportError.cancelled }
            var target = rels[sheetRef.relationID] ?? "worksheets/sheet\(i + 1).xml"
            if target.hasPrefix("/") { target.removeFirst() }
            let entryPath = target.hasPrefix("xl/") ? target : "xl/" + target

            progress(ImportProgress(stage: "extracting \(sheetRef.name)",
                                    fraction: 0.1 + 0.9 * (Double(i) / Double(max(1, sheets.count))),
                                    rowsDone: 0, sheetName: sheetRef.name))

            guard let sheetURL = try extractToFile(entry: entryPath, in: archive, dir: work) else { continue }
            defer { try? FileManager.default.removeItem(at: sheetURL) }

            try importSheet(fileURL: sheetURL,
                            name: sheetRef.name,
                            index: i,
                            workbookID: wbID,
                            sharedStrings: sharedStrings,
                            dateStyles: dateStyles,
                            fillColors: fillColors,
                            date1904: wbParser.date1904,
                            headerMode: headerMode,
                            workDir: work,
                            sheetProgressBase: 0.1 + 0.9 * (Double(i) / Double(max(1, sheets.count))),
                            sheetProgressSpan: 0.9 / Double(max(1, sheets.count)),
                            progress: progress)
            importedAnySheet = true
        }

        if !importedAnySheet {
            try? workspace.deleteWorkbook(wbID)
            throw ImportError.corrupt("no readable sheets found")
        }
        return wbID
    }

    private func importSheet(fileURL: URL, name: String, index: Int, workbookID: Int64,
                             sharedStrings: [String], dateStyles: Set<Int>, fillColors: [Int: UInt32],
                             date1904: Bool, headerMode: HeaderMode, workDir: URL,
                             sheetProgressBase: Double, sheetProgressSpan: Double,
                             progress: @escaping (ImportProgress) -> Void) throws {
        let sheetID = try workspace.createSheet(workbookID: workbookID, name: name, index: index)
        let tableName = "data_\(sheetID)"

        var header: [String] = []
        var writer: TableWriter?
        var rowsWritten = 0
        let cancel = cancelFlag

        // Fill colours are spooled to disk while parsing, then bulk-loaded in one pass.
        let spool = try FillSpool(directory: workDir)
        defer { spool.remove() }

        // Header detection buffers the first rows (or everything for small sheets)
        // before deciding which one is the header.
        var buffer: [[DBValue]] = []
        var decided = false

        func flushDecision() throws {
            decided = true
            let decision = HeaderDetector.decide(mode: headerMode, buffer: buffer)
            header = decision.header
            let width = max(header.count, buffer.map { $0.count }.max() ?? 0)
            writer = try TableWriter(db: workspace.db, tableName: tableName, columnCount: max(1, width))
            let firstDataIndex = (decision.headerIndex ?? -1) + 1
            if firstDataIndex < buffer.count, let w = writer {
                for row in buffer[firstDataIndex...] {
                    try w.write(row)
                    rowsWritten += 1
                }
            }
            buffer.removeAll(keepingCapacity: true)
        }

        let parserDelegate = SheetXMLParser(
            sharedStrings: sharedStrings,
            dateStyles: dateStyles,
            date1904: date1904,
            fillColors: fillColors,
            onRow: { row in
                if !decided {
                    buffer.append(row)
                    if buffer.count >= HeaderDetector.sampleLimit {
                        try flushDecision()
                    }
                    return
                }
                guard let writer else { return }
                try writer.write(row)
                rowsWritten += 1
                if rowsWritten % 5_000 == 0 {
                    progress(ImportProgress(stage: "importing \(name)",
                                            fraction: sheetProgressBase + sheetProgressSpan * 0.5,
                                            rowsDone: rowsWritten, sheetName: name))
                }
            },
            onFillRow: { seq, fills in
                try spool.append(seq: seq, fills: fills)
            })
        parserDelegate.shouldCancel = cancel

        guard let parser = XMLParser(contentsOf: fileURL) else {
            throw ImportError.corrupt("cannot open sheet xml")
        }
        parser.delegate = parserDelegate
        parser.shouldProcessNamespaces = false
        let parsed = parser.parse()

        if let err = parserDelegate.thrownError {
            _ = try? writer?.finish()
            throw err
        }

        guard parsed else { _ = try? writer?.finish(); throw ImportError.corrupt("malformed worksheet XML") }
        if !decided { try flushDecision() }
        let total = try writer?.finish() ?? 0

        // Pad header to the real column count.
        let columnCount = max(writer?.currentColumnCount ?? header.count, header.count)
        if header.count < columnCount {
            for i in header.count..<columnCount { header.append("Column \(CellRef.name(forIndex: i))") }
        }
        if header.isEmpty { header = ["Column A"] }
        if writer == nil {
            // Completely empty sheet: still create a placeholder table.
            _ = try TableWriter(db: workspace.db, tableName: tableName, columnCount: 1).finish()
        }

        // Bulk-load the spooled fill colours (parser seq -> data rowid).
        let dropped = parserDelegate.emittedRows - rowsWritten
        try SheetFillStorage.importSpool(workspace: workspace, sheetID: sheetID, tableName: tableName, spool: spool, dropped: dropped,
                                         name: name, cancelled: cancelFlag, progress: progress)

        let columns = try SchemaInspector.classify(db: workspace.db, tableName: tableName,
                                                   headers: header, dateHints: parserDelegate.dateColumns)
        try workspace.saveColumns(sheetID: sheetID, columns: columns)
        try workspace.setRowCount(sheetID: sheetID, count: total)
        // Keep the query planner's statistics fresh after big imports.
        try? workspace.db.exec("PRAGMA optimize;")
        progress(ImportProgress(stage: "finished \(name)", fraction: sheetProgressBase + sheetProgressSpan,
                                rowsDone: total, sheetName: name))
    }

    // MARK: - zip helpers

    private func data(for path: String, in archive: Archive) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        var out = Data()
        _ = try archive.extract(entry, bufferSize: 1 << 16, skipCRC32: true) { chunk in
            out.append(chunk)
        }
        return out
    }

    private func extractToFile(entry path: String, in archive: Archive, dir: URL) throws -> URL? {
        guard let entry = archive[path] else { return nil }
        let out = dir.appendingPathComponent(UUID().uuidString + ".xml")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: out.path) else { return nil }
        defer { try? handle.close() }
        _ = try archive.extract(entry, bufferSize: 1 << 18, skipCRC32: true) { chunk in
            handle.write(chunk)
        }
        return out
    }
}

// MARK: - Column type classification

enum SchemaInspector {
    static func classify(db: Database, tableName: String, headers: [String], dateHints: Set<Int>) throws -> [ColumnInfo] {
        var columns: [ColumnInfo] = []
        let sample = 800
        for (i, rawName) in headers.enumerated() {
            let col = "c\(i)"
            var kind: ColumnKind = .text
            let exists = (try? db.scalar("SELECT COUNT(*) FROM pragma_table_info(\(tableName.sqlLiteral)) WHERE name=\(col.sqlLiteral)")) ?? .int(0)
            if (exists.doubleValue ?? 0) > 0 {
                let sql = """
                SELECT
                  SUM(CASE WHEN typeof(\(col)) IN ('integer','real') THEN 1 ELSE 0 END),
                  SUM(CASE WHEN \(col) IS NOT NULL AND typeof(\(col))='text' AND length(\(col))>0 THEN 1 ELSE 0 END),
                  SUM(CASE WHEN typeof(\(col))='text' AND (\(col) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*') THEN 1 ELSE 0 END),
                  SUM(CASE WHEN upper(CAST(\(col) AS TEXT)) IN ('TRUE','FALSE') THEN 1 ELSE 0 END),
                  COUNT(*)
                FROM (SELECT \(col) FROM \(tableName.sqlIdentifier) LIMIT \(sample))
                """
                if let row = try? db.query(sql).first, row.count >= 5 {
                    let nums = row[0].doubleValue ?? 0
                    let texts = row[1].doubleValue ?? 0
                    let dates = row[2].doubleValue ?? 0
                    let bools = row[3].doubleValue ?? 0
                    let total = max(1, row[4].doubleValue ?? 1)
                    if dates / total > 0.5 || dateHints.contains(i) {
                        kind = .date
                    } else if bools / total > 0.8 {
                        kind = .boolean
                    } else if nums / max(1, nums + texts) > 0.8 && nums > 0 {
                        kind = .number
                    }
                }
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            columns.append(ColumnInfo(index: i, name: name.isEmpty ? "Column \(CellRef.name(forIndex: i))" : name, kind: kind))
        }
        return columns
    }
}
