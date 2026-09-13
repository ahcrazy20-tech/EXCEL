import XCTest
@testable import SheetX

final class CellColorTests: XCTestCase {
    private func parse(_ xml: String, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: Data(xml.utf8)); parser.delegate = delegate
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "XML parse")
    }

    func testIndexedPaletteHas64EntriesAndStandardPrimaryColors() {
        XCTAssertEqual(XLSXColor.indexedPalette.count, 64)
        XCTAssertEqual(XLSXColor.resolve(["indexed": "10"], theme: []), 0xFFFF0000)
        XCTAssertEqual(XLSXColor.resolve(["indexed": "12"], theme: []), 0xFF0000FF)
        XCTAssertEqual(XLSXColor.resolve(["indexed": "13"], theme: []), 0xFFFFFF00)
        XCTAssertNil(XLSXColor.resolve(["indexed": "64"], theme: []))
        XCTAssertNil(XLSXColor.resolve(["indexed": "-1"], theme: []))
    }

    func testRGBWithZeroAlphaIsAnOpaqueSpreadsheetFill() {
        XCTAssertEqual(XLSXColor.resolve(["rgb": "00FF0000"], theme: []), 0xFFFF0000)
        XCTAssertEqual(XLSXColor.resolve(["rgb": "00FF00"], theme: []), 0xFF00FF00)
        XCTAssertEqual(FillCodec.decode("0:00FF0000;1:FFFFFFFF"), [0: 0xFFFF0000, 1: 0xFFFFFFFF])
        XCTAssertNil(XLSXColor.parseHex("invalid"))
    }

    func testPrefixedThemeParsesAndUsesSpreadsheetThemeOrder() throws {
        let parser = ThemeParser()
        try parse("""
            <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements><a:clrScheme name="Test">
            <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
            <a:dk2><a:srgbClr val="1F497D"/></a:dk2><a:lt2><a:srgbClr val="EEECE1"/></a:lt2>
            <a:accent1><a:srgbClr val="4F81BD"/></a:accent1><a:accent2><a:srgbClr val="C0504D"/></a:accent2>
            </a:clrScheme></a:themeElements></a:theme>
            """, delegate: parser)
        let palette = XLSXColor.themePalette(fromScheme: parser.scheme)
        XCTAssertEqual(palette.count, 6)
        XCTAssertEqual(palette[0], 0xFFFFFFFF)
        XCTAssertEqual(palette[1], 0xFF000000)
        XCTAssertEqual(palette[4], 0xFF4F81BD)
        XCTAssertEqual(XLSXColor.resolve(["theme": "4"], theme: palette), 0xFF4F81BD)
    }

    func testTextContrastIsIndependentOfDarkMode() {
        XCTAssertTrue(FillCodec.prefersBlackText(0xFFFFFFFF))
        XCTAssertTrue(FillCodec.prefersBlackText(0xFFFFFF00))
        XCTAssertTrue(FillCodec.prefersBlackText(0xFFFF0000))
        XCTAssertFalse(FillCodec.prefersBlackText(0xFF000000))
        XCTAssertFalse(FillCodec.prefersBlackText(0xFF0000FF))
    }

    func testSystemThemeUsesSavedLastColor() throws {
        let parser = ThemeParser()
        try parse("<a:theme xmlns:a=\"urn:theme\"><a:clrScheme><a:lt1><a:sysClr val=\"window\" lastClr=\"ABCDEF\"/></a:lt1></a:clrScheme></a:theme>", delegate: parser)
        XCTAssertEqual(parser.scheme, [0xFFABCDEF])
    }

    func testTintUsesHLSLuminanceAndClamps() {
        XCTAssertEqual(XLSXColor.applyTint(0xFF4F81BD, 0.4), 0xFF95B3D7)
        XCTAssertEqual(XLSXColor.applyTint(0xFF4F81BD, -1), 0xFF000000)
        XCTAssertEqual(XLSXColor.applyTint(0xFF4F81BD, 2), 0xFFFFFFFF)
        XCTAssertEqual(XLSXColor.applyTint(0xFF4F81BD, .nan), 0xFF4F81BD)
    }

    func testStylesResolveThemesAndRetainExplicitWhite() throws {
        let parser = StylesParser()
        try parse("""
            <x:styleSheet xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <x:fills count="4"><x:fill><x:patternFill patternType="none"/></x:fill>
            <x:fill><x:patternFill patternType="solid"><x:fgColor theme="4"/></x:patternFill></x:fill>
            <x:fill><x:patternFill patternType="solid"><x:fgColor rgb="00FFFFFF"/></x:patternFill></x:fill>
            <x:fill><x:gradientFill><x:stop position="0"><x:color rgb="FFFF0000"/></x:stop></x:gradientFill></x:fill></x:fills>
            <x:cellXfs count="5"><x:xf fillId="0"/><x:xf fillId="1"/><x:xf fillId="2"/><x:xf fillId="3"/><x:xf fillId="-1"/></x:cellXfs>
            </x:styleSheet>
            """, delegate: parser)
        XCTAssertNil(parser.fillColors[0])
        XCTAssertEqual(parser.fillColors[1], 0xFF4F81BD)
        XCTAssertEqual(parser.fillColors[2], 0xFFFFFFFF)
        XCTAssertNil(parser.fillColors[3])
        XCTAssertNil(parser.fillColors[4])
    }

    func testBlankStyledRowsCannotLeakFillsIntoNextDataRow() throws {
        var fills: [Int: [Int: UInt32]] = [:], rows: [[DBValue]] = []
        let parser = SheetXMLParser(sharedStrings: [], dateStyles: [], date1904: false, fillColors: [1: 0xFFFF0000],
                                    onRow: { rows.append($0) }, onFillRow: { fills[$0] = $1 })
        try parse("""
            <worksheet><sheetData><row r="1"><c r="A1" s="1"/></row>
            <row r="2"><c r="A2"><v>10</v></c></row></sheetData></worksheet>
            """, delegate: parser)
        XCTAssertEqual(rows, [[.int(10)]])
        XCTAssertTrue(fills.isEmpty)
    }

    func testPrefixedCellsRespectExplicitRowAndColumnFillPrecedence() throws {
        var fills: [Int: [Int: UInt32]] = [:]
        let parser = SheetXMLParser(sharedStrings: [], dateStyles: [], date1904: false,
            fillColors: [1: 0xFFFF0000, 2: 0xFF0000FF], onRow: { _ in }, onFillRow: { fills[$0] = $1 })
        try parse("""
            <x:worksheet xmlns:x="urn:sheet"><x:cols><x:col min="1" max="3" style="1"/></x:cols><x:sheetData>
            <x:row r="1" s="2" customFormat="1"><x:c r="A1"><x:v>1</x:v></x:c><x:c r="C1" s="0"><x:v>3</x:v></x:c></x:row>
            <x:row r="2"><x:c r="A2"><x:v>2</x:v></x:c></x:row>
            </x:sheetData></x:worksheet>
            """, delegate: parser)
        XCTAssertEqual(fills[1]?[0], 0xFF0000FF)
        XCTAssertEqual(fills[1]?[1], 0xFF0000FF) // sparse B1 inherits row style
        XCTAssertNil(fills[1]?[2]) // explicit no-fill overrides inheritance
        XCTAssertEqual(fills[2]?[0], 0xFFFF0000)
    }

    func testSpoolStoresDetectedHeaderAtZeroAndKeepsFilteredRowColorsAligned() throws {
        let fixture = try AnalysisFixture(rows: [[.text("A"), .int(1)], [.text("B"), .int(2)]])
        let spool = try FillSpool(directory: fixture.directory)
        defer { spool.remove() }
        try spool.append(seq: 1, fills: [0: 0xFF000000]) // report title, dropped
        try spool.append(seq: 2, fills: [0: 0xFF0000FF]) // header
        try spool.append(seq: 3, fills: [0: 0xFFFF0000])
        try spool.append(seq: 4, fills: [1: 0xFF00FF00])
        try SheetFillStorage.importSpool(workspace: fixture.workspace, sheetID: fixture.sheet.id,
            tableName: fixture.sheet.tableName, spool: spool, dropped: 2, name: "Test", progress: { _ in })
        let sheet = try XCTUnwrap(fixture.workspace.loadSheets(workbookID: fixture.sheet.workbookID).first)
        XCTAssertTrue(sheet.hasColors)
        let engine = QueryEngine(db: fixture.db, sheet: sheet)
        let header = try engine.fetchFills(rowids: [0])
        XCTAssertEqual(FillCodec.decode(header[0] ?? ""), [0: 0xFF0000FF])
        var query = QuerySpec(); query.filters = [FilterCondition(columnIndex: 0, op: .equals, value: "B")]
        let rows = try engine.fetchRows(query, offset: 0, limit: 200)
        XCTAssertEqual(rows.first?.first, .int(2))
        XCTAssertEqual(FillCodec.decode(try engine.fetchFills(rowids: [2])[2] ?? ""), [1: 0xFF00FF00])
    }

    func testSpoolWithoutHeaderKeepsFirstDataRowAtOne() throws {
        let fixture = try AnalysisFixture()
        let spool = try FillSpool(directory: fixture.directory); defer { spool.remove() }
        try spool.append(seq: 1, fills: [0: 0xFFFF0000])
        try SheetFillStorage.importSpool(workspace: fixture.workspace, sheetID: fixture.sheet.id,
            tableName: fixture.sheet.tableName, spool: spool, dropped: 0, name: "Test", progress: { _ in })
        XCTAssertEqual(try fixture.db.scalar("SELECT rowid FROM \(fixture.sheet.fillsTableName)"), .int(1))
    }

    func testFillSpoolClosedWriteAndCancellationReportErrors() throws {
        let fixture = try AnalysisFixture()
        let spool = try FillSpool(directory: fixture.directory); defer { spool.remove() }
        spool.close()
        XCTAssertThrowsError(try spool.append(seq: 1, fills: [0: 0xFFFF0000]))
        XCTAssertThrowsError(try SheetFillStorage.importSpool(workspace: fixture.workspace, sheetID: fixture.sheet.id,
            tableName: fixture.sheet.tableName, spool: spool, dropped: 0, name: "Test", cancelled: { true }, progress: { _ in }))
    }
}
