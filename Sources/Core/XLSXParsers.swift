import Foundation

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

final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var buffer = ""
    private var inSI = false
    private var inT = false
    private var skipPhonetic = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let elementName = elementName.split(separator: ":").last.map(String.init) ?? elementName
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
        let elementName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch elementName {
        case "si": strings.append(buffer); inSI = false; buffer = ""
        case "t": inT = false
        case "rPh", "phoneticPr": skipPhonetic = false
        default: break
        }
    }
}

final class StylesParser: NSObject, XMLParserDelegate {
    /// styleIndex -> isDateFormat
    var dateStyles: Set<Int> = []
    /// styleIndex -> fill colour (ARGB), including explicit white fills.
    var fillColors: [Int: UInt32] = [:]
    private var customDateFormats: Set<Int> = []
    private var inCellXfs = false
    private var xfIndex = 0

    // fills parsing state
    private let themePalette: [UInt32]
    private var inFills = false
    private var inFill = false
    private var solidPattern = false
    private var fgARGB: UInt32?
    private var fillTable: [UInt32?] = []   // fillId -> colour (nil = none)
    private var xfFills: [UInt32?] = []     // styleIndex -> colour

    private static let builtinDateIDs: Set<Int> = [14, 15, 16, 17, 18, 19, 20, 21, 22,
                                                   27, 30, 36, 45, 46, 47, 50, 57, 58]

    init(themePalette: [UInt32] = XLSXColor.defaultTheme) {
        self.themePalette = themePalette
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let elementName = elementName.split(separator: ":").last.map(String.init) ?? elementName
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
        case "fills":
            inFills = true
            fillTable.removeAll()
        case "fill" where inFills:
            inFill = true
            solidPattern = false
            fgARGB = nil
        case "patternFill" where inFill:
            solidPattern = (attributeDict["patternType"] == "solid")
        case "fgColor" where inFill:
            fgARGB = XLSXColor.resolve(attributeDict, theme: themePalette)
        case "cellXfs":
            inCellXfs = true
            xfIndex = 0
            xfFills.removeAll()
        case "xf":
            if inCellXfs {
                if let idStr = attributeDict["numFmtId"], let id = Int(idStr),
                   StylesParser.builtinDateIDs.contains(id) || customDateFormats.contains(id) {
                    dateStyles.insert(xfIndex)
                }
                let fillID = Int(attributeDict["fillId"] ?? "") ?? 0
                xfFills.append(fillID >= 0 && fillID < fillTable.count ? fillTable[fillID] : nil)
                xfIndex += 1
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let elementName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch elementName {
        case "fill" where inFills:
            inFill = false
            fillTable.append(solidPattern ? fgARGB : nil)
        case "fills":
            inFills = false
        case "cellXfs":
            inCellXfs = false
        default: break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        // Explicit white is meaningful in dark mode and must not be discarded.
        for (style, fill) in xfFills.enumerated() {
            if let c = fill {
                fillColors[style] = c
            }
        }
    }
}

struct WorkbookSheetRef {
    var name: String
    var relationID: String
    var sheetID: String
}

final class WorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [WorkbookSheetRef] = []
    var date1904 = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let elementName = elementName.split(separator: ":").last.map(String.init) ?? elementName
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

final class RelsParser: NSObject, XMLParserDelegate {
    var map: [String: String] = [:]  // rId -> target

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let elementName = elementName.split(separator: ":").last.map(String.init) ?? elementName
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
    private let fillColors: [Int: UInt32]           // style index -> fill ARGB
    private let onRow: ([DBValue]) throws -> Void
    private let onFillRow: (Int, [Int: UInt32]) throws -> Void

    private var currentRow: [DBValue] = []
    private var cellColumn = 0
    private var cellType = ""
    private var cellStyle = -1
    private var cellFill: UInt32?
    private var explicitStyleColumns: Set<Int> = []
    private var rowStyle: Int?
    private var columnStyles: [Int: Int] = [:]
    private var rowFills: [Int: UInt32] = [:]
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
         fillColors: [Int: UInt32] = [:],
         onRow: @escaping ([DBValue]) throws -> Void,
         onFillRow: @escaping (Int, [Int: UInt32]) throws -> Void = { _, _ in }) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
        self.date1904 = date1904
        self.fillColors = fillColors
        self.onRow = onRow
        self.onFillRow = onFillRow
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let elementName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch elementName {
        case "col":
            if let first = Int(attributeDict["min"] ?? ""), let last = Int(attributeDict["max"] ?? ""),
               first > 0, last >= first, last <= 16384, let style = Int(attributeDict["style"] ?? "") {
                for column in (first - 1)..<last { columnStyles[column] = style }
            }
        case "row":
            rowStyle = ["1", "true"].contains(attributeDict["customFormat"] ?? "") ? Int(attributeDict["s"] ?? "") : nil
            inRow = true
            currentRow.removeAll(keepingCapacity: true)
            rowFills.removeAll(keepingCapacity: true)
            explicitStyleColumns.removeAll(keepingCapacity: true)
            cellColumn = 0
        case "c":
            cellType = attributeDict["t"] ?? "n"
            if let ref = attributeDict["r"], let idx = CellRef.columnIndex(fromRef: ref) {
                cellColumn = idx
            }
            if attributeDict["s"] != nil { explicitStyleColumns.insert(cellColumn) }
            cellStyle = Int(attributeDict["s"] ?? "") ?? rowStyle ?? columnStyles[cellColumn] ?? 0
            cellFill = fillColors[cellStyle]
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
        let elementName = elementName.split(separator: ":").last.map(String.init) ?? elementName
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
            if let fill = cellFill { rowFills[cellColumn] = fill }
            cellFill = nil
            cellColumn += 1
            textBuffer = ""
        case "row":
            inRow = false
            maxColumns = max(maxColumns, currentRow.count)
            if !currentRow.allSatisfy({ if case .null = $0 { return true } else { return false } }) {
                do {
                    for column in currentRow.indices where rowFills[column] == nil && !explicitStyleColumns.contains(column) {
                        if let fill = fillColors[rowStyle ?? columnStyles[column] ?? 0] { rowFills[column] = fill }
                    }
                    try onRow(currentRow)
                    emittedRows += 1
                    if !rowFills.isEmpty { try onFillRow(emittedRows, rowFills) }
                } catch {
                    thrownError = error
                    parser.abortParsing()
                }
                rowFills.removeAll(keepingCapacity: true)
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

