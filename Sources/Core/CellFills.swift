import Foundation
import SwiftUI
import UIKit

// MARK: - XLSX colour resolution

/// Resolves the many ways an XLSX file can spell a colour:
/// `rgb="FFFF0000"`, `indexed="10"`, `theme="4" tint="0.4"` (plus sysClr in themes).
enum XLSXColor {
    /// Legacy 64-colour indexed palette (ECMA-376 §18.8.27), opaque.
    static let indexedPalette: [UInt32] = [
        0xFF000000, 0xFFFFFFFF, 0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFF00FFFF, 0xFFFF00FF, 0xFF000000,
        0xFFFFFFFF, 0xFF000000, 0xFFFFFF00, 0xFF00FF00, 0xFF00FFFF, 0xFF0000FF, 0xFFFF00FF, 0xFFFFFFFF,
        0xFF800000, 0xFF008000, 0xFF000080, 0xFF808000, 0xFF800080, 0xFF008080, 0xFFC0C0C0, 0xFF808080,
        0xFF9999FF, 0xFF993366, 0xFFFFFFCC, 0xFFCCFFFF, 0xFF660066, 0xFFFF8080, 0xFF0066CC, 0xFFCCCCFF,
        0xFF000080, 0xFFFF00FF, 0xFFFFFF00, 0xFF00FFFF, 0xFF800080, 0xFF800000, 0xFF008080, 0xFF0000FF,
        0xFF00CCFF, 0xFFCCFFFF, 0xFFCCFFCC, 0xFFFFFF99, 0xFF99CCFF, 0xFFFF99CC, 0xFFCC99FF, 0xFFFFCC99,
        0xFF3366FF, 0xFF33CCCC, 0xFF99CC00, 0xFFFF9900, 0xFFFF6600, 0xFF666699, 0xFF969696, 0xFF003366,
        0xFF339966, 0xFF003300, 0xFF333300, 0xFF993300, 0xFF993366, 0xFF333399, 0xFF333333
    ]

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
        return base
    }

    /// OOXML tint approximation (same formula POI uses): tint < 0 darkens, > 0 lightens.
    static func applyTint(_ argb: UInt32, _ tint: Double) -> UInt32 {
        let t = max(-1, min(1, tint))
        func channel(_ v: UInt32) -> UInt32 {
            let c = Double(v)
            let out = t < 0 ? c * (1 + t) : c * (1 - t) + 255 * t
            return UInt32(max(0, min(255, out.rounded())))
        }
        let r = channel((argb >> 16) & 0xFF)
        let g = channel((argb >> 8) & 0xFF)
        let b = channel(argb & 0xFF)
        return 0xFF00_0000 | (r << 16) | (g << 8) | b
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
        if elementName == "clrScheme" { inScheme = true; scheme = [] }
        guard inScheme else { return }
        switch elementName {
        case "srgbClr":
            current = XLSXColor.parseHex(attributeDict["val"] ?? "")
        case "sysClr":
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

    init(directory: URL) {
        url = directory.appendingPathComponent("fills-\(UUID().uuidString).spool")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = FileHandle(forWritingAtPath: url.path)
    }

    /// Line format: `rowSeq;colIndex:argbHex;colIndex:argbHex…`
    func append(seq: Int, fills: [Int: UInt32]) {
        guard let handle else { return }
        var line = "\(seq)"
        for (col, argb) in fills.sorted(by: { $0.key < $1.key }) {
            line += ";\(col):\(String(format: "%08X", argb))"
        }
        line += "\n"
        handle.write(line.data(using: .utf8)!)
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

    func nextLine() -> String? {
        while true {
            if let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl])
                pending.removeSubrange(pending.startIndex...nl)
                if !line.isEmpty { return line }
                continue
            }
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
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
    /// Parses a stored `f` value (`"3:FFED7D00;7:FFCC0000"`) into col → ARGB.
    static func decode(_ s: String) -> [Int: UInt32] {
        guard !s.isEmpty else { return [:] }
        var out: [Int: UInt32] = [:]
        for pair in s.split(separator: ";") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let col = Int(parts[0]), let argb = UInt32(parts[1], radix: 16) else { continue }
            out[col] = argb
        }
        return out
    }
}

// MARK: - SwiftUI colour helpers

extension Color {
    init(argb: UInt32) {
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Perceived brightness 0…1 (used to pick readable text colour over fills).
    var luminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
    }
}
