import Foundation
import UIKit
import ZIPFoundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv, xlsx, json, html, pdf, markdown
    var id: String { rawValue }
    var fileExtension: String { self == .markdown ? "md" : rawValue }
    var display: String { rawValue.uppercased() }
}

enum Exporter {

    static func tempURL(name: String, ext: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(safe).\(ext)")
    }

    // MARK: CSV

    static func csv(table: ResultTable, name: String, delimiter: String = ",") throws -> URL {
        let url = tempURL(name: name, ext: "csv")
        FileManager.default.createFile(atPath: url.path, contents: Data([0xEF, 0xBB, 0xBF]))
        guard let handle = FileHandle(forWritingAtPath: url.path) else { throw ImportError.corrupt("cannot write") }
        defer { try? handle.close() }
        try handle.seekToEnd()

        func field(_ s: String) -> String {
            if s.contains(delimiter) || s.contains("\"") || s.contains("\n") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        var buffer = table.columns.map(field).joined(separator: delimiter) + "\r\n"
        var counter = 0
        for row in table.rows {
            buffer += row.map { field($0.stringValue) }.joined(separator: delimiter) + "\r\n"
            counter += 1
            if counter % 2000 == 0 {
                handle.write(Data(buffer.utf8))
                buffer = ""
            }
        }
        handle.write(Data(buffer.utf8))
        return url
    }

    /// Streams a whole (possibly filtered) sheet to CSV without loading it all in memory.
    static func csvStreaming(engine: QueryEngine, query: QuerySpec, name: String,
                             progress: ((Double) -> Void)? = nil) throws -> URL {
        let url = tempURL(name: name, ext: "csv")
        FileManager.default.createFile(atPath: url.path, contents: Data([0xEF, 0xBB, 0xBF]))
        guard let handle = FileHandle(forWritingAtPath: url.path) else { throw ImportError.corrupt("cannot write") }
        defer { try? handle.close() }
        try handle.seekToEnd()

        func field(_ s: String) -> String {
            if s.contains(",") || s.contains("\"") || s.contains("\n") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }

        let total = try engine.countRows(query)
        handle.write(Data((engine.sheet.columns.map { field($0.name) }.joined(separator: ",") + "\r\n").utf8))

        let pageSize = 5000
        var offset = 0
        while offset < total {
            let rows = try engine.fetchRows(query, offset: offset, limit: pageSize)
            if rows.isEmpty { break }
            var buffer = ""
            for r in rows {
                buffer += r.dropFirst().map { field($0.stringValue) }.joined(separator: ",") + "\r\n"
            }
            handle.write(Data(buffer.utf8))
            offset += rows.count
            progress?(Double(offset) / Double(max(1, total)))
        }
        return url
    }

    // MARK: JSON

    static func json(table: ResultTable, name: String) throws -> URL {
        var array: [[String: Any]] = []
        for row in table.rows {
            var obj: [String: Any] = [:]
            for (i, col) in table.columns.enumerated() where i < row.count {
                switch row[i] {
                case .int(let v): obj[col] = v
                case .double(let v): obj[col] = v
                case .text(let s): obj[col] = s
                case .null: obj[col] = NSNull()
                }
            }
            array.append(obj)
        }
        let data = try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .withoutEscapingSlashes])
        let url = tempURL(name: name, ext: "json")
        try data.write(to: url)
        return url
    }

    // MARK: XLSX

    static func xlsx(table: ResultTable, name: String, sheetName: String = "Sheet1") throws -> URL {
        let url = tempURL(name: name, ext: "xlsx")
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="\(xmlEscape(String(sheetName.prefix(28))))" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>
        </styleSheet>
        """

        var sheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """
        func cell(_ ref: String, _ value: DBValue, header: Bool) -> String {
            let style = header ? " s=\"1\"" : ""
            switch value {
            case .int(let v): return "<c r=\"\(ref)\"\(style)><v>\(v)</v></c>"
            case .double(let v) where v.isFinite: return "<c r=\"\(ref)\"\(style)><v>\(v)</v></c>"
            case .null: return "<c r=\"\(ref)\"\(style)/>"
            default:
                return "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(xmlEscape(value.stringValue))</t></is></c>"
            }
        }
        sheetXML += "<row r=\"1\">"
        for (i, c) in table.columns.enumerated() {
            sheetXML += cell("\(CellRef.name(forIndex: i))1", .text(c), header: true)
        }
        sheetXML += "</row>"
        for (rIdx, row) in table.rows.enumerated() {
            let rowNum = rIdx + 2
            sheetXML += "<row r=\"\(rowNum)\">"
            for (cIdx, value) in row.enumerated() {
                sheetXML += cell("\(CellRef.name(forIndex: cIdx))\(rowNum)", value, header: false)
            }
            sheetXML += "</row>"
        }
        sheetXML += "</sheetData></worksheet>"

        try add(archive, "[Content_Types].xml", contentTypes)
        try add(archive, "_rels/.rels", rootRels)
        try add(archive, "xl/workbook.xml", workbook)
        try add(archive, "xl/_rels/workbook.xml.rels", workbookRels)
        try add(archive, "xl/styles.xml", styles)
        try add(archive, "xl/worksheets/sheet1.xml", sheetXML)
        return url
    }

    private static func add(_ archive: Archive, _ path: String, _ text: String) throws {
        let data = Data(text.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: .deflate) { position, size -> Data in
            let start = Int(position)
            let end = min(start + size, data.count)
            guard start < end else { return Data() }
            return data.subdata(in: start..<end)
        }
    }

    static func xmlEscape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        out = String(out.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 })
        return out
    }

    // MARK: Text / HTML / PDF

    static func text(_ content: String, name: String, ext: String) throws -> URL {
        let url = tempURL(name: name, ext: ext)
        try Data(content.utf8).write(to: url)
        return url
    }

    @MainActor
    static func pdf(html: String, name: String) throws -> URL {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        let pageSize = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4 @72dpi
        let printable = pageSize.insetBy(dx: 28, dy: 34)
        renderer.setValue(NSValue(cgRect: pageSize), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, pageSize, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()

        let url = tempURL(name: name, ext: "pdf")
        try data.write(to: url, options: .atomic)
        return url
    }
}
