import Foundation

/// Streaming delimited-text importer (CSV / TSV / pipe / semicolon), RFC-4180 aware.
/// Reads in 4 MB chunks so a 1 GB CSV never lands in memory.
final class CSVImporter {
    private let workspace: Workspace
    private let cancelFlag: () -> Bool

    init(workspace: Workspace, cancelFlag: @escaping () -> Bool = { false }) {
        self.workspace = workspace
        self.cancelFlag = cancelFlag
    }

    static func detectDelimiter(sample: String) -> Character {
        let candidates: [Character] = [",", ";", "\t", "|"]
        var best: Character = ","
        var bestScore = -1
        let lines = sample.split(separator: "\n", maxSplits: 20, omittingEmptySubsequences: true).prefix(20)
        for c in candidates {
            var counts: [Int] = []
            for l in lines { counts.append(l.filter { $0 == c }.count) }
            let total = counts.reduce(0, +)
            guard total > 0 else { continue }
            let consistent = Set(counts).count <= 2 ? 1000 : 0
            let score = total + consistent
            if score > bestScore { bestScore = score; best = c }
        }
        return best
    }

    func importFile(url: URL, delimiter: Character?, headerRow: Bool,
                    progress: @escaping (ImportProgress) -> Void) throws -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ImportError.corrupt("cannot open file")
        }
        defer { try? handle.close() }

        // Sniff the delimiter from the first 64 KB.
        let sniff = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        let sniffText = String(data: sniff, encoding: .utf8) ?? String(decoding: sniff, as: UTF8.self)
        let delim = delimiter ?? CSVImporter.detectDelimiter(sample: sniffText)
        try handle.seek(toOffset: 0)

        let wbID = try workspace.createWorkbook(
            name: url.deletingPathExtension().lastPathComponent,
            fileName: url.lastPathComponent,
            size: size)
        let sheetName = url.deletingPathExtension().lastPathComponent
        let sheetID = try workspace.createSheet(workbookID: wbID, name: sheetName, index: 0)
        let tableName = "data_\(sheetID)"

        var header: [String] = []
        var writer: TableWriter?
        var rows = 0
        var bytesRead: Int64 = 0
        var isFirst = true

        let parser = DelimitedParser(delimiter: delim)
        var thrown: Error?

        while true {
            if cancelFlag() { thrown = ImportError.cancelled; break }
            guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { break }
            bytesRead += Int64(chunk.count)
            parser.feed(chunk) { fields in
                if isFirst {
                    isFirst = false
                    if headerRow {
                        header = fields.enumerated().map { i, f in
                            let t = f.trimmingCharacters(in: .whitespacesAndNewlines)
                            return t.isEmpty ? "Column \(CellRef.name(forIndex: i))" : t
                        }
                        writer = try? TableWriter(db: self.workspace.db, tableName: tableName, columnCount: max(1, header.count))
                        return
                    }
                    header = (0..<max(1, fields.count)).map { "Column \(CellRef.name(forIndex: $0))" }
                    writer = try? TableWriter(db: self.workspace.db, tableName: tableName, columnCount: max(1, fields.count))
                }
                guard let writer else { return }
                do {
                    try writer.write(fields.map(ValueCoercion.fromString))
                    rows += 1
                } catch { thrown = error }
                if rows % 20_000 == 0 {
                    let frac = size > 0 ? Double(bytesRead) / Double(size) : -1
                    progress(ImportProgress(stage: "importing", fraction: min(0.98, frac), rowsDone: rows, sheetName: sheetName))
                }
            }
            if thrown != nil { break }
        }

        parser.finish { fields in
            guard let writer, !(fields.count == 1 && fields[0].isEmpty) else { return }
            try? writer.write(fields.map(ValueCoercion.fromString))
            rows += 1
        }

        if let thrown {
            _ = try? writer?.finish()
            try? workspace.deleteWorkbook(wbID)
            throw thrown
        }

        let total = try writer?.finish() ?? 0
        let columnCount = max(writer?.currentColumnCount ?? header.count, header.count)
        if header.count < columnCount {
            for i in header.count..<columnCount { header.append("Column \(CellRef.name(forIndex: i))") }
        }
        if header.isEmpty {
            header = ["Column A"]
            _ = try TableWriter(db: workspace.db, tableName: tableName, columnCount: 1).finish()
        }

        let columns = try SchemaInspector.classify(db: workspace.db, tableName: tableName, headers: header, dateHints: [])
        try workspace.saveColumns(sheetID: sheetID, columns: columns)
        try workspace.setRowCount(sheetID: sheetID, count: total)
        progress(ImportProgress(stage: "done", fraction: 1, rowsDone: total, sheetName: sheetName))
        return wbID
    }
}

/// Incremental RFC-4180 parser fed with arbitrary byte chunks.
final class DelimitedParser {
    private let delimiter: UInt8
    private var field = [UInt8]()
    private var fields: [String] = []
    private var inQuotes = false
    private var quoteJustClosed = false

    init(delimiter: Character) {
        self.delimiter = delimiter.asciiValue ?? 44
        field.reserveCapacity(64)
    }

    func feed(_ data: Data, emit: ([String]) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                let b = bytes[i]
                i += 1
                if inQuotes {
                    if b == 0x22 {           // "
                        if quoteJustClosed {
                            field.append(0x22)
                            quoteJustClosed = false
                        } else {
                            quoteJustClosed = true
                        }
                        continue
                    }
                    if quoteJustClosed {
                        inQuotes = false
                        quoteJustClosed = false
                        // fall through to normal handling of this byte
                    } else {
                        field.append(b)
                        continue
                    }
                }
                switch b {
                case 0x22:                    // "
                    if field.isEmpty { inQuotes = true } else { field.append(b) }
                case delimiter:
                    pushField()
                case 0x0A:                    // \n
                    pushField()
                    emit(fields)
                    fields.removeAll(keepingCapacity: true)
                case 0x0D:                    // \r  (handled as part of CRLF)
                    break
                default:
                    field.append(b)
                }
            }
        }
    }

    func finish(emit: ([String]) -> Void) {
        if inQuotes && quoteJustClosed { inQuotes = false }
        if !field.isEmpty || !fields.isEmpty {
            pushField()
            emit(fields)
            fields.removeAll(keepingCapacity: true)
        }
    }

    private func pushField() {
        var s = String(decoding: field, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        fields.append(s)
        field.removeAll(keepingCapacity: true)
    }
}

/// Imports a JSON array of flat objects.
final class JSONImporter {
    private let workspace: Workspace
    init(workspace: Workspace) { self.workspace = workspace }

    func importFile(url: URL, progress: @escaping (ImportProgress) -> Void) throws -> Int64 {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        var array: [[String: Any]] = []
        if let a = obj as? [[String: Any]] {
            array = a
        } else if let d = obj as? [String: Any] {
            if let firstArray = d.values.compactMap({ $0 as? [[String: Any]] }).first {
                array = firstArray
            } else {
                array = [d]
            }
        }
        guard !array.isEmpty else { throw ImportError.unsupported("JSON has no tabular array") }

        var keys: [String] = []
        var seen = Set<String>()
        for row in array.prefix(500) {
            for k in row.keys where !seen.contains(k) { seen.insert(k); keys.append(k) }
        }
        keys.sort()

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let wbID = try workspace.createWorkbook(name: url.deletingPathExtension().lastPathComponent,
                                                fileName: url.lastPathComponent, size: size)
        let sheetID = try workspace.createSheet(workbookID: wbID, name: url.deletingPathExtension().lastPathComponent, index: 0)
        let tableName = "data_\(sheetID)"
        let writer = try TableWriter(db: workspace.db, tableName: tableName, columnCount: keys.count)

        var count = 0
        for row in array {
            let values: [DBValue] = keys.map { key in
                guard let v = row[key] else { return .null }
                switch v {
                case let n as NSNumber:
                    if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
                    return .int(n.int64Value)
                case let s as String: return s.isEmpty ? .null : .text(s)
                case is NSNull: return .null
                default:
                    if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) {
                        return .text(String(decoding: d, as: UTF8.self))
                    }
                    return .text(String(describing: v))
                }
            }
            try writer.write(values)
            count += 1
            if count % 10_000 == 0 {
                progress(ImportProgress(stage: "importing", fraction: Double(count) / Double(array.count),
                                        rowsDone: count, sheetName: ""))
            }
        }
        let total = try writer.finish()
        let columns = try SchemaInspector.classify(db: workspace.db, tableName: tableName, headers: keys, dateHints: [])
        try workspace.saveColumns(sheetID: sheetID, columns: columns)
        try workspace.setRowCount(sheetID: sheetID, count: total)
        return wbID
    }
}
