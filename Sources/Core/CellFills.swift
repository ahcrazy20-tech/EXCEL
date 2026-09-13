import Foundation

// MARK: - XLSX colour resolution

/// Resolves the many ways an XLSX file can spell a colour:
/// `rgb="FFFF0000"`, `indexed="10"`, `theme="4" tint="0.4"` (plus sysClr in themes).
enum XLSXColor {
    /// Legacy 64-colour indexed palette (ECMA-376 §18.8.27), opaque.
    static let indexedPalette: [UInt32] = [
        0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFFFF00FF, 0xFF00FFFF,
        0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFFFF00FF, 0xFF00FFFF,
        0xFF800000, 0xFF008000, 0xFF000080, 0xFF808000, 0xFF800080, 0xFF008080, 0xFFC0C0C0, 0xFF808080,
        0xFF9999FF, 0xFF993366, 0xFFFFFFCC, 0xFFCCFFFF, 0xFF660066, 0xFFFF8080, 0xFF0066CC, 0xFFCCCCFF,
        0xFF000080, 0xFFFF00FF, 0xFFFFFF00, 0xFF00FFFF, 0xFF800080, 0xFF800000, 0xFF008080, 0xFF0000FF,
        0xFF00CCFF, 0xFFCCFFFF, 0xFFCCFFCC, 0xFFFFFF99, 0xFF99CCFF, 0xFFFF99CC, 0xFFCC99FF, 0xFFFFCC99,
        0xFF3366FF, 0xFF33CCCC, 0xFF99CC00, 0xFFFFCC00, 0xFFFF9900, 0xFFFF6600, 0xFF666699, 0xFF969696,
        0xFF003366, 0xFF339966, 0xFF003300, 0xFF333300, 0xFF993300, 0xFF993366, 0xFF333399, 0xFF333333,
    ]

    static let defaultTheme: [UInt32] = [0xFFFFFFFF, 0xFF000000, 0xFFEEECE1, 0xFF1F497D,
        0xFF4F81BD, 0xFFC0504D, 0xFF9BBB59, 0xFF8064A2, 0xFF4BACC6, 0xFFF79646, 0xFF0000FF, 0xFF800080]

    /// `rgb` may be `RRGGBB` or `AARRGGBB`.
    static func parseHex(_ s: String) -> UInt32? {
        let hex = s.count == 6 ? "FF" + s : s
        guard hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        return UInt32(truncatingIfNeeded: v)
    }

    /// Resolves a colour element's attributes (`rgb`, `indexed`, `theme`, `tint`).
    static func resolve(_ attrs: [String: String], theme: [UInt32]) -> UInt32? {
        var base: UInt32?
        if let rgb = attrs["rgb"] { base = parseHex(rgb) }
        if base == nil, let idx = attrs["indexed"].flatMap({ Int($0) }) {
            if idx >= 0, idx < indexedPalette.count { base = indexedPalette[idx] }
        }
        if base == nil, let t = attrs["theme"].flatMap({ Int($0) }), t >= 0, t < theme.count {
            base = theme[t]
        }
        if let b = base, let tint = attrs["tint"].flatMap({ Double($0) }), tint != 0 {
            return applyTint(b, tint)
        }
        // Spreadsheet fills are opaque; many generators encode RGB with alpha 00.
        return base.map { $0 | 0xFF000000 }
    }

    /// OOXML tint changes HLS luminance, not the individual RGB channels.
    static func applyTint(_ argb: UInt32, _ tint: Double) -> UInt32 {
        guard tint.isFinite else { return argb | 0xFF000000 }
        let r = Double((argb >> 16) & 255) / 255, g = Double((argb >> 8) & 255) / 255, b = Double(argb & 255) / 255
        let hi = max(r, g, b), lo = min(r, g, b), delta = hi - lo
        let light = (hi + lo) / 2
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * light - 1))
        var hue = 0.0
        if delta != 0 {
            if hi == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if hi == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let t = max(-1, min(1, tint))
        let l = t < 0 ? light * (1 + t) : light * (1 - t) + t
        let c = (1 - abs(2 * l - 1)) * saturation
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let rgb: (Double, Double, Double)
        switch hue * 6 {
        case ..<1: rgb = (c, x, 0)
        case ..<2: rgb = (x, c, 0)
        case ..<3: rgb = (0, c, x)
        case ..<4: rgb = (0, x, c)
        case ..<5: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        func byte(_ value: Double) -> UInt32 { UInt32(max(0, min(255, ((value + m) * 255).rounded()))) }
        return 0xFF000000 | byte(rgb.0) << 16 | byte(rgb.1) << 8 | byte(rgb.2)
    }

    /// Maps a `clrScheme` colour list (file order: dk1 lt1 dk2 lt2 accent1-6 hlink folHlink)
    /// to the indices the `theme="n"` attribute uses (0/1 and 2/3 are swapped).
    static func themePalette(fromScheme scheme: [UInt32]) -> [UInt32] {
        var p = scheme
        if p.count >= 4 { p.swapAt(0, 1); p.swapAt(2, 3) }
        return p
    }
}

// MARK: - theme1.xml parser

final class ThemeParser: NSObject, XMLParserDelegate {
    private(set) var scheme: [UInt32] = []
    private var current: UInt32?
    private var inScheme = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let elementName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if elementName == "clrScheme" { inScheme = true; scheme = [] }
        guard inScheme else { return }
        switch elementName {
        case "srgbClr":
            current = XLSXColor.parseHex(attributeDict["val"] ?? "")
        case "sysClr":
            if let cached = attributeDict["lastClr"].flatMap({ XLSXColor.parseHex($0) }) {
                current = cached
                return
            }
            switch attributeDict["val"] {
            case "window": current = 0xFFFFFFFF
            case "windowText": current = 0xFF000000
            default:
                current = attributeDict["lastClr"].flatMap { XLSXColor.parseHex($0) }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let elementName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        guard inScheme else { return }
        switch elementName {
        case "dk1", "lt1", "dk2", "lt2",
             "accent1", "accent2", "accent3", "accent4", "accent5", "accent6",
             "hlink", "folHlink":
            scheme.append(current ?? 0xFF000000)
            current = nil
        case "clrScheme":
            inScheme = false
        default: break
        }
    }
}

// MARK: - Fill spool (streamed to disk during parse, bulk-loaded afterwards)

/// Streams per-row fill colours to a temp file so millions of coloured rows
/// never sit in memory and never fight the data table's write transaction.
final class FillSpool {
    let url: URL
    private var handle: FileHandle?
    private(set) var count = 0

    init(directory: URL) throws {
        url = directory.appendingPathComponent("fills-\(UUID().uuidString).spool")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ImportError.corrupt("cannot create color spool") }
        handle = try FileHandle(forWritingTo: url)
    }

    /// Line format: `rowSeq;colIndex:argbHex;colIndex:argbHex…`
    func append(seq: Int, fills: [Int: UInt32]) throws {
        guard let handle else { throw ImportError.corrupt("color spool is closed") }
        var line = "\(seq)"
        for (col, argb) in fills.sorted(by: { $0.key < $1.key }) {
            line += ";\(col):\(String(format: "%08X", argb))"
        }
        line += "\n"
        try handle.write(contentsOf: Data(line.utf8))
        count += 1
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    func remove() {
        close()
        try? FileManager.default.removeItem(at: url)
    }
}

/// Chunked line reader over a spool file (keeps memory flat).
final class FillSpoolReader {
    private let handle: FileHandle
    private var pending = ""

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func nextLine() throws -> String? {
        while true {
            if let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl])
                pending.removeSubrange(pending.startIndex...nl)
                if !line.isEmpty { return line }
                continue
            }
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                try? handle.close()
                guard !pending.isEmpty else { return nil }
                let last = pending
                pending = ""
                return last.isEmpty ? nil : last
            }
            pending += String(decoding: chunk, as: UTF8.self)
        }
    }
}

// MARK: - Encoding helpers shared with the UI

enum FillCodec {
    /// Choose black/white using relative luminance contrast, independent of iOS appearance.
    static func prefersBlackText(_ argb: UInt32) -> Bool {
        func linear(_ value: UInt32) -> Double {
            let s = Double(value) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((argb >> 16) & 255) + 0.7152 * linear((argb >> 8) & 255) + 0.0722 * linear(argb & 255)
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
    }

    /// Parses a stored `f` value (`"3:FFED7D00;7:FFCC0000"`) into col → ARGB.
    static func decode(_ s: String) -> [Int: UInt32] {
        guard !s.isEmpty else { return [:] }
        var out: [Int: UInt32] = [:]
        for pair in s.split(separator: ";") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let col = Int(parts[0]), let argb = UInt32(parts[1], radix: 16) else { continue }
            out[col] = argb | 0xFF000000
        }
        return out
    }
}


enum SheetFillStorage {
    /// Loads the spooled per-row fill colours into a compact side table `data_N_f`.
    static func importSpool(workspace: Workspace, sheetID: Int64, tableName: String, spool: FillSpool, dropped: Int,
                                  name: String, cancelled: () -> Bool = { false }, progress: @escaping (ImportProgress) -> Void) throws {
        guard !cancelled() else { throw ImportError.cancelled }
        guard spool.count > 0 else { return }
        spool.close()
        progress(ImportProgress(stage: "importing colors (\(name))", fraction: -1, rowsDone: 0, sheetName: name))

        let fTable = (tableName + "_f").sqlIdentifier
        try workspace.db.exec("DROP TABLE IF EXISTS \(fTable);")
        try workspace.db.exec("CREATE TABLE \(fTable)(rowid INTEGER PRIMARY KEY, f TEXT NOT NULL);")

        let reader = try FillSpoolReader(url: spool.url)
        var done = 0
        try workspace.db.bulkInsert(sql: "INSERT INTO \(fTable)(rowid,f) VALUES(?,?)") {
            while let line = try reader.nextLine() {
                guard let semi = line.firstIndex(of: ";"),
                      let seq = Int(line[..<semi]) else { continue }
                let rowid = seq - dropped
                guard rowid >= 0 else { continue }   // rowid 0 stores the detected header fill; titles above it are omitted
                if done % 1024 == 0 && cancelled() { throw ImportError.cancelled }
                done += 1
                if done % 100_000 == 0 {
                    progress(ImportProgress(stage: "importing colors (\(name))", fraction: -1,
                                            rowsDone: done, sheetName: name))
                }
                return [.int(Int64(rowid)), .text(String(line[line.index(after: semi)...]))]
            }
            return nil
        }
        try workspace.setHasColors(sheetID: sheetID, done > 0)
    }

}
