import Foundation
import ZIPFoundation

struct ImportProgress {
    var stage: String
    var fraction: Double      // 0...1, -1 when indeterminate
    var rowsDone: Int
    var sheetName: String
}

enum ImportError: LocalizedError {
    case unsupported(String)
    case corrupt(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Unsupported file: \(s)"
        case .corrupt(let s): return "Could not read file: \(s)"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Excel serial dates

enum ExcelDate {
    static let base = Date(timeIntervalSince1970: -2_209_161_600) // 1899-12-30 UTC

    static func date(fromSerial serial: Double) -> Date {
        Date(timeIntervalSince1970: base.timeIntervalSince1970 + serial * 86_400.0)
    }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(fromSerial serial: Double) -> String {
        let d = date(fromSerial: serial)
        let frac = serial - serial.rounded(.down)
        return frac < 1e-6 ? dayFormatter.string(from: d) : isoFormatter.string(from: d)
    }
}

// MARK: - Column reference helpers

enum CellRef {
    /// "BC12" -> 54 (0-based column index)
    static func columnIndex(fromRef ref: String) -> Int? {
        var value = 0
        var sawLetter = false
        for ch in ref.utf8 {
            if ch >= 65 && ch <= 90 {        // A-Z
                value = value * 26 + Int(ch - 64)
                sawLetter = true
            } else if ch >= 97 && ch <= 122 { // a-z
                value = value * 26 + Int(ch - 96)
                sawLetter = true
            } else {
                break
            }
        }
        return sawLetter ? value - 1 : nil
    }

    /// 0 -> "A", 27 -> "AB"
    static func name(forIndex index: Int) -> String {
        var n = index + 1
        var out = ""
        while n > 0 {
            let rem = (n - 1) % 26
            out = String(UnicodeScalar(UInt8(65 + rem))) + out
            n = (n - 1) / 26
        }
        return out
    }
}

// MARK: - Small SAX helpers

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var buffer = ""
    private var inSI = false
    private var inT = false
    private var skipPhonetic = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "si": inSI = true; buffer = ""
        case "t": inT = !skipPhonetic
        case "rPh", "phoneticPr": skipPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inSI && inT { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "si": strings.append(buffer); inSI = false; buffer = ""
        case "t": inT = false
        case "rPh", "phoneticPr": skipPhonetic = false
        default: break
        }
    }
}

private final class StylesParser: NSObject, XMLParserDelegate {
    /// styleIndex -> isDateFormat
    var dateStyles: Set<Int> = []
    private var customDateFormats: Set<Int> = []
    private var inCellXfs = false
    private var xfIndex = 0

    private static let builtinDateIDs: Set<Int> = [14, 15, 16, 17, 18, 19, 20, 21, 22,
                                                   27, 30, 36, 45, 46, 47, 50, 57, 58]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "numFmt":
            if let idStr = attributeDict["numFmtId"], let id = Int(idStr),
               let code = attributeDict["formatCode"] {
                let stripped = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
                    .lowercased()
                if stripped.contains("y") || stripped.contains("d") || stripped.contains("m:")
                    || stripped.contains("h") || stripped.contains("mmm") {
                    if stripped.contains("y") || stripped.contains("d") || stripped.contains("h") {
                        customDateFormats.insert(id)
                    }
                }
            }
        case "cellXfs":
            inCellXfs = true
            xfIndex = 0
        case "xf":
            if inCellXfs {
                if let idStr = attributeDict["numFmtId"], let id = Int(idStr),
                   StylesParser.builtinDateIDs.contains(id) || customDateFormats.contains(id) {
                    dateStyles.insert(xfIndex)
                }
                xfIndex += 1
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "cellXfs" { inCellXfs = false }
    }
}

private struct WorkbookSheetRef {
    var name: String
    var relationID: String
    var sheetID: String
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [WorkbookSheetRef] = []
    var date1904 = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "sheet" {
            sheets.append(WorkbookSheetRef(
                name: attributeDict["name"] ?? "Sheet\(sheets.count + 1)",
                relationID: attributeDict["r:id"] ?? attributeDict["id"] ?? "",
                sheetID: attributeDict["sheetId"] ?? ""))
        } else if elementName == "workbookPr" {
            date1904 = (attributeDict["date1904"] == "1" || attributeDict["date1904"] == "true")
        }
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    var map: [String: String] = [:]  // rId -> target

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "Relationship", let id = attributeDict["Id"], let target = attributeDict["Target"] {
            map[id] = target
        }
    }
}

// MARK: - Sheet SAX parser (streams rows out through a callback)

final class SheetXMLParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let dateStyles: Set<Int>
    private let date1904: Bool
    private let onRow: ([DBValue]) throws -> Void

    private var currentRow: [DBValue] = []
    private var cellColumn = 0
    private var cellType = ""
    private var cellStyle = -1
    private var textBuffer = ""
    private var capturing = false
    private var inRow = false
    private var inFormula = false
    private(set) var maxColumns = 0
    private(set) var dateColumns: Set<Int> = []
    private(set) var emittedRows = 0
    var thrownError: Error?
    var shouldCancel: () -> Bool = { false }

    init(sharedStrings: [String], dateStyles: Set<Int>, date1904: Bool,
         onRow: @escaping ([DBValue]) throws -> Void) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
        self.date1904 = date1904
        self.onRow = onRow
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row":
            inRow = true
            currentRow.removeAll(keepingCapacity: true)
            cellColumn = 0
        case "c":
            cellType = attributeDict["t"] ?? "n"
            cellStyle = Int(attributeDict["s"] ?? "") ?? -1
            if let ref = attributeDict["r"], let idx = CellRef.columnIndex(fromRef: ref) {
                cellColumn = idx
            }
            textBuffer = ""
        case "v", "t":
            capturing = !inFormula
            if elementName == "v" { textBuffer = "" }
        case "f":
            inFormula = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { textBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "f":
            inFormula = false
        case "v", "t":
            capturing = false
        case "c":
            let value = makeValue()
            while currentRow.count < cellColumn { currentRow.append(.null) }
            if currentRow.count == cellColumn {
                currentRow.append(value)
            } else if cellColumn < currentRow.count {
                currentRow[cellColumn] = value
            }
            cellColumn += 1
            textBuffer = ""
        case "row":
            inRow = false
            maxColumns = max(maxColumns, currentRow.count)
            if !currentRow.allSatisfy({ if case .null = $0 { return true } else { return false } }) {
                do {
                    try onRow(currentRow)
                    emittedRows += 1
                } catch {
                    thrownError = error
                    parser.abortParsing()
                }
            }
            if emittedRows & 0x3FF == 0, shouldCancel() {
                thrownError = ImportError.cancelled
                parser.abortParsing()
            }
        default: break
        }
    }

    private func makeValue() -> DBValue {
        let raw = textBuffer
        switch cellType {
        case "s":
            if let idx = Int(raw), idx >= 0, idx < sharedStrings.count { return .text(sharedStrings[idx]) }
            return .null
        case "str", "inlineStr":
            return raw.isEmpty ? .null : .text(raw)
        case "b":
            return .text(raw == "1" ? "TRUE" : "FALSE")
        case "e":
            return raw.isEmpty ? .null : .text(raw)
        default:
            if raw.isEmpty { return .null }
            if cellStyle >= 0, dateStyles.contains(cellStyle), let serial = Double(raw) {
                dateColumns.insert(cellColumn)
                let adjusted = date1904 ? serial + 1462 : serial
                return .text(ExcelDate.string(fromSerial: adjusted))
            }
            if let i = Int64(raw) { return .int(i) }
            if let d = Double(raw) { return .double(d) }
            return .text(raw)
        }
    }
}

// MARK: - Importer

final class XLSXImporter {
    private let workspace: Workspace
    private let cancelFlag: () -> Bool

    init(workspace: Workspace, cancelFlag: @escaping () -> Bool = { false }) {
        self.workspace = workspace
        self.cancelFlag = cancelFlag
    }

    /// Imports a .xlsx/.xlsm workbook. Returns the created workbook id.
    func importWorkbook(url: URL, headerRow: Bool, progress: @escaping (ImportProgress) -> Void) throws -> Int64 {
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

        // 3. styles (for date detection)
        var dateStyles: Set<Int> = []
        if let stylesData = try data(for: "xl/styles.xml", in: archive) {
            let sp = StylesParser()
            let p = XMLParser(data: stylesData); p.delegate = sp; p.parse()
            dateStyles = sp.dateStyles
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
                            date1904: wbParser.date1904,
                            headerRow: headerRow,
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
                             sharedStrings: [String], dateStyles: Set<Int>, date1904: Bool,
                             headerRow: Bool, sheetProgressBase: Double, sheetProgressSpan: Double,
                             progress: @escaping (ImportProgress) -> Void) throws {
        let sheetID = try workspace.createSheet(workbookID: workbookID, name: name, index: index)
        let tableName = "data_\(sheetID)"

        var header: [String] = []
        var writer: TableWriter?
        var rowsWritten = 0
        var isFirstRow = true
        let cancel = cancelFlag

        let parserDelegate = SheetXMLParser(sharedStrings: sharedStrings, dateStyles: dateStyles, date1904: date1904) { row in
            if isFirstRow {
                isFirstRow = false
                if headerRow {
                    header = row.enumerated().map { idx, v in
                        let s = v.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        return s.isEmpty ? "Column \(CellRef.name(forIndex: idx))" : s
                    }
                    writer = try TableWriter(db: self.workspace.db, tableName: tableName, columnCount: max(1, header.count))
                    return
                } else {
                    header = (0..<max(1, row.count)).map { "Column \(CellRef.name(forIndex: $0))" }
                    writer = try TableWriter(db: self.workspace.db, tableName: tableName, columnCount: max(1, row.count))
                }
            }
            guard let writer else { return }
            try writer.write(row)
            rowsWritten += 1
            if rowsWritten % 5_000 == 0 {
                progress(ImportProgress(stage: "importing \(name)",
                                        fraction: sheetProgressBase + sheetProgressSpan * 0.5,
                                        rowsDone: rowsWritten, sheetName: name))
            }
        }
        parserDelegate.shouldCancel = cancel

        guard let parser = XMLParser(contentsOf: fileURL) else {
            throw ImportError.corrupt("cannot open sheet xml")
        }
        parser.delegate = parserDelegate
        parser.shouldProcessNamespaces = false
        parser.parse()

        if let err = parserDelegate.thrownError {
            _ = try? writer?.finish()
            throw err
        }

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

        let columns = try SchemaInspector.classify(db: workspace.db, tableName: tableName,
                                                   headers: header, dateHints: parserDelegate.dateColumns)
        try workspace.saveColumns(sheetID: sheetID, columns: columns)
        try workspace.setRowCount(sheetID: sheetID, count: total)
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
