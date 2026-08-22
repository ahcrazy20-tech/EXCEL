import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Thread-safe cancellation flag shared with background importers.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published var workbooks: [WorkbookInfo] = []
    @Published var importing = false
    @Published var progress: ImportProgress?
    @Published var errorMessage: String?
    @Published var reports: [Workspace.StoredReport] = []

    private let cancelBox = CancelBox()
    let workspace = Workspace.shared

    private init() { reload() }

    func reload() {
        do {
            workbooks = try workspace.loadWorkbooks()
            reports = try workspace.loadReports()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelImport() { cancelBox.cancel() }

    nonisolated static let supportedTypes: [UTType] = {
        var types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .json, .plainText, .text, .data]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.insert(xlsx, at: 0) }
        if let xlsm = UTType(filenameExtension: "xlsm") { types.insert(xlsm, at: 1) }
        return types
    }()

    func importFiles(_ urls: [URL], headerRow: Bool) {
        guard !importing else { return }
        importing = true
        cancelBox.reset()
        progress = ImportProgress(stage: "starting", fraction: 0, rowsDone: 0, sheetName: "")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await self.importOne(url: url, headerRow: headerRow)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await MainActor.run { self.errorMessage = "\(url.lastPathComponent): \(message)" }
                }
            }
            await MainActor.run {
                self.importing = false
                self.progress = nil
                self.reload()
            }
        }
    }

    private nonisolated func importOne(url: URL, headerRow: Bool) async throws {
        let ext = url.pathExtension.lowercased()
        let ws = Workspace.shared
        let box = self.cancelBox
        let cancel: () -> Bool = { box.value }
        let report: (ImportProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.progress = p }
        }

        // Copy into the sandbox first: importing directly from an iCloud/Files URL can stall.
        let localURL = try Library.stageLocally(url)
        defer { try? FileManager.default.removeItem(at: localURL) }

        switch ext {
        case "xlsx", "xlsm", "xltx":
            _ = try XLSXImporter(workspace: ws, cancelFlag: cancel)
                .importWorkbook(url: localURL, headerRow: headerRow, progress: report)
        case "csv", "tsv", "txt", "tab":
            let delim: Character? = (ext == "tsv" || ext == "tab") ? "\t" : nil
            _ = try CSVImporter(workspace: ws, cancelFlag: cancel)
                .importFile(url: localURL, delimiter: delim, headerRow: headerRow, progress: report)
        case "json":
            _ = try JSONImporter(workspace: ws).importFile(url: localURL, progress: report)
        case "xls":
            throw ImportError.unsupported("Legacy .xls — please re-save as .xlsx")
        default:
            // Try to sniff: zip magic -> xlsx, otherwise delimited text.
            let handle = try FileHandle(forReadingFrom: localURL)
            let magic = try handle.read(upToCount: 2) ?? Data()
            try? handle.close()
            if magic == Data([0x50, 0x4B]) {
                _ = try XLSXImporter(workspace: ws, cancelFlag: cancel)
                    .importWorkbook(url: localURL, headerRow: headerRow, progress: report)
            } else {
                _ = try CSVImporter(workspace: ws, cancelFlag: cancel)
                    .importFile(url: localURL, delimiter: nil, headerRow: headerRow, progress: report)
            }
        }
    }

    nonisolated static func stageLocally(_ url: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try data.write(to: dest)
        }
        return dest
    }

    func delete(workbook: WorkbookInfo) {
        do {
            try workspace.deleteWorkbook(workbook.id)
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteAll() {
        for wb in workbooks { try? workspace.deleteWorkbook(wb.id) }
        for r in reports { try? workspace.deleteReport(r.id) }
        reload()
    }

    func saveReport(sheetID: Int64, title: String, body: String) {
        try? workspace.saveReport(sheetID: sheetID, title: title, body: body)
        reload()
    }

    func deleteReport(_ id: Int64) {
        try? workspace.deleteReport(id)
        reload()
    }

    var databaseSize: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: workspace.db.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Generates a demo dataset so the app is useful before any import.
    func createSampleData() {
        guard !importing else { return }
        importing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SheetX Demo.csv")
            var csv = "Order ID,Date,Customer,City,Category,Product,Quantity,Unit Price,Total,Status\n"
            let cities = ["Jeddah", "Riyadh", "Dammam", "Mecca", "Medina", "Abha"]
            let categories = ["Electronics", "Grocery", "Fashion", "Home", "Sports"]
            let statuses = ["Delivered", "Pending", "Cancelled", "Returned"]
            var seed: UInt64 = 20_260_822
            func rnd(_ n: Int) -> Int {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((seed >> 33) % UInt64(max(1, n)))
            }
            for i in 1...20_000 {
                let qty = 1 + rnd(20)
                let price = Double(5 + rnd(900)) + Double(rnd(100)) / 100
                let total = Double(qty) * price
                let day = 1 + rnd(28)
                let month = 1 + rnd(12)
                csv += "ORD-\(10_000 + i),2025-\(String(format: "%02d", month))-\(String(format: "%02d", day)),"
                csv += "Customer \(1 + rnd(2500)),\(cities[rnd(cities.count)]),\(categories[rnd(categories.count)]),"
                csv += "SKU-\(100 + rnd(400)),\(qty),\(String(format: "%.2f", price)),\(String(format: "%.2f", total)),"
                csv += "\(statuses[rnd(statuses.count)])\n"
            }
            try? Data(csv.utf8).write(to: url)
            do {
                _ = try CSVImporter(workspace: Workspace.shared)
                    .importFile(url: url, delimiter: ",", headerRow: true) { p in
                        Task { @MainActor in self.progress = p }
                    }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            try? FileManager.default.removeItem(at: url)
            await MainActor.run {
                self.importing = false
                self.progress = nil
                self.reload()
            }
        }
    }
}
