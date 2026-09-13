import Foundation

/// A bounded UI window into the already-loaded query result (not database paging).
/// Even a 5,000 × 256 result creates at most 50 × 8 visible cell views.
struct ResultPageWindow {
    let rowRange: Range<Int>
    let columnRange: Range<Int>
    let rowPage: Int
    let columnPage: Int
    let rowPageCount: Int
    let columnPageCount: Int

    init(rows: Int, columns: Int, rowPage: Int, columnPage: Int,
         pageSize: Int = 12, columnPageSize: Int = 6) {
        let rowCount = max(0, rows), columnCount = max(0, columns)
        let rowSize = max(1, min(pageSize, 50)), columnSize = max(1, min(columnPageSize, 8))
        rowPageCount = rowCount == 0 ? 1 : (rowCount - 1) / rowSize + 1
        columnPageCount = columnCount == 0 ? 1 : (columnCount - 1) / columnSize + 1
        self.rowPage = min(max(0, rowPage), rowPageCount - 1)
        self.columnPage = min(max(0, columnPage), columnPageCount - 1)
        let rowStart = self.rowPage * rowSize, columnStart = self.columnPage * columnSize
        rowRange = rowStart..<(rowStart + min(rowSize, rowCount - rowStart))
        columnRange = columnStart..<(columnStart + min(columnSize, columnCount - columnStart))
    }
}

enum TextPages {
    /// Split once away from the UI thread, without cutting a Unicode grapheme.
    static func split(_ text: String, pageSize: Int = 6000) -> [String] {
        let size = max(1, pageSize)
        var pages: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            pages.append(String(text[start..<end]))
            start = end
        }
        return pages.isEmpty ? [""] : pages
    }
}
