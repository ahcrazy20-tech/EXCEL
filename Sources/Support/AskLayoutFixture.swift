#if DEBUG
import SwiftUI

/// Isolated in-memory UI fixture. No imports, API requests or user-data deletion.
@MainActor
struct AskLayoutFixtureHost: View {
    @State private var open = false
    @State private var model: SheetViewModel?
    @State private var error: String?

    private static let table = ResultTable(
        columns: (0..<200).map { "Long column heading \($0) " + String(repeating: "X", count: 100) },
        rows: (0..<500).map { row in (0..<200).map { column in DBValue.text("R\(row) C\(column)") } })
    private static let response = String(repeating: "A long Arabic and English response. بيانات للتحليل.\n", count: 5000)

    var body: some View {
        VStack {
            if let error { Text(error) }
            Button("Open large Ask fixture") { open = true }
                .disabled(model == nil).accessibilityIdentifier("fixture.openAsk")
        }
        .task {
            do {
                let database = try Database(path: ":memory:")
                try database.exec("CREATE TABLE data_1(c0 TEXT);")
                let sheet = SheetInfo(id: 1, workbookID: 1, name: "UI test", tableName: "data_1", rowCount: 0,
                                      columns: [ColumnInfo(index: 0, name: "Value", kind: .text)], index: 0)
                model = SheetViewModel(sheet: sheet, database: database)
            } catch { self.error = error.localizedDescription }
        }
        .fullScreenCover(isPresented: $open) {
            if let model { AskView(layoutTestModel: model, result: Self.table, narrative: Self.response) }
        }
    }
}
#endif
