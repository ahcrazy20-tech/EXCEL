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
    @Published private(set) var deleting = false
    var storageBusy: Bool { importing || deleting }
    @Published var progress: ImportProgress?
    @Published var errorMessage: String?
    @Published var reports: [Workspace.StoredReport] = []

    private let cancelBox = CancelBox()
    private var catalogueGeneration = 0
    let workspace = Workspace.shared

    private init() { reload() }

    func reload() {
        catalogueGeneration += 1
        do {
            workbooks = try workspace.loadWorkbooks()
            reports = try workspace.loadReports()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadInBackground() async {
        guard !storageBusy else { return }
        let generation = catalogueGeneration
        let workspace = self.workspace
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                (try workspace.loadWorkbooks(), try workspace.loadReports())
            }.value
            // A deletion publishes its own authoritative catalogue after commit.
            guard !storageBusy, generation == catalogueGeneration else { return }
            workbooks = snapshot.0
            reports = snapshot.1
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelImport() { cancelBox.cancel() }

    nonisolated static let supportedTypes: [UTType] = {
        var types: [UTType] = []
        // Excel formats — resolve by system identifier first, then by extension.
        let excel: [(String, String)] = [
            ("org.openxmlformats.spreadsheetml.sheet", "xlsx"),               // .xlsx
            ("org.openxmlformats.spreadsheetml.sheet.macroenabled", "xlsm"),  // .xlsm
            ("org.openxmlformats.spreadsheetml.template", "xltx"),            // .xltx
            ("org.openxmlformats.spreadsheetml.template.macroenabled", "xltm")
        ]
        for (identifier, ext) in excel {
            if let t = UTType(identifier) {
                types.append(t)
            } else if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        types.append(contentsOf: [.commaSeparatedText, .tabSeparatedText, .json,
                                  .plainText, .text, .data, .item])
        return types
    }()

    func importFiles(_ urls: [URL], headerMode: HeaderMode, importColors: Bool? = nil) {
        guard !storageBusy else { return }
        importing = true
        cancelBox.reset()
        progress = ImportProgress(stage: "starting", fraction: 0, rowsDone: 0, sheetName: "")
        let colors = importColors ?? AppSettings.shared.importCellColors

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await self.importOne(url: url, headerMode: headerMode, importColors: colors)
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

    private nonisolated func importOne(url: URL, headerMode: HeaderMode, importColors: Bool) async throws {
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
        case "xlsx", "xlsm", "xltx", "xltm":
            _ = try XLSXImporter(workspace: ws, cancelFlag: cancel)
                .importWorkbook(url: localURL, headerMode: headerMode, importColors: importColors, progress: report)
        case "csv", "tsv", "txt", "tab":
            let delim: Character? = (ext == "tsv" || ext == "tab") ? "\t" : nil
            _ = try CSVImporter(workspace: ws, cancelFlag: cancel)
                .importFile(url: localURL, delimiter: delim, headerMode: headerMode, progress: report)
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
                    .importWorkbook(url: localURL, headerMode: headerMode, importColors: importColors, progress: report)
            } else {
                _ = try CSVImporter(workspace: ws, cancelFlag: cancel)
                    .importFile(url: localURL, delimiter: nil, headerMode: headerMode, progress: report)
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

    func delete(sheet: SheetInfo) async -> Bool {
        let workspace = self.workspace
        return await removeSheets { try workspace.deleteSheet(sheet.id, workbookID: sheet.workbookID) }
    }

    func delete(workbook: WorkbookInfo) async -> Bool {
        let workspace = self.workspace
        return await removeSheets(removingWorkbook: workbook.id) { try workspace.deleteWorkbook(workbook.id) }
    }

    private func removeSheets(removingWorkbook: Int64? = nil,
                              operation: @escaping () throws -> [Int64]) async -> Bool {
        guard !storageBusy else { errorMessage = "files.storageBusy".loc; return false }
        deleting = true
        catalogueGeneration += 1
        defer { deleting = false }
        do {
            let deleted = try await Task.detached(priority: .userInitiated) { try operation() }.value
            let ids = Set(deleted)
            catalogueGeneration += 1
            SheetViewModel.removeLayouts(for: ids)
            // Update the visible catalogue only after the transaction commits.
            workbooks = workbooks.compactMap { workbook in
                if workbook.id == removingWorkbook { return nil }
                var updated = workbook
                let affected = workbook.sheets.contains { ids.contains($0.id) }
                updated.sheets.removeAll { ids.contains($0.id) }
                return affected && updated.sheets.isEmpty ? nil : updated
            }
            reports.removeAll { ids.contains($0.sheetID) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteAll() {
        guard !storageBusy else { return }
        Task {
            // Use the same guarded asynchronous path; stop at the first failure.
            for workbook in workbooks {
                if !(await delete(workbook: workbook)) { break }
            }
        }
    }

    func saveReport(sheetID: Int64, title: String, body: String) {
        do {
            try workspace.saveReport(sheetID: sheetID, title: title, body: body)
            reload()
        } catch { errorMessage = error.localizedDescription }
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
        guard !storageBusy else { return }
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
                    .importFile(url: url, delimiter: ",", headerMode: .always) { p in
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
