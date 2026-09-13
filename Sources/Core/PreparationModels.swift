import Foundation

/// A preparation always reads immutable sources and produces a new sheet.
struct PreparationSource: Codable, Hashable {
    let id: Int64
    let workbookID: Int64
    let tableName: String
    let name: String
    let rowCount: Int
    let columns: [AnalysisColumnSignature]

    init(_ sheet: SheetInfo) {
        id = sheet.id; workbookID = sheet.workbookID; tableName = sheet.tableName
        name = sheet.name; rowCount = sheet.rowCount
        columns = sheet.columns.map { AnalysisColumnSignature(index: $0.index, name: $0.name, kind: $0.kind) }
    }

    func validateStructure() throws {
        guard id > 0, tableName == "data_\(id)", rowCount >= 0,
              !columns.isEmpty, columns.count <= PreparationLimits.columns,
              columns.map(\.index) == Array(0..<columns.count) else { throw PreparationError.sourceChanged }
    }
}

enum JoinMode: String, Codable, CaseIterable, Identifiable {
    case left, inner, lookup
    var id: String { rawValue }
    var title: String { "prep.join.\(rawValue)".loc }
}

enum JoinKeyMode: String, Codable, CaseIterable, Identifiable {
    case exact, normalizedText
    var id: String { rawValue }
    var title: String { "prep.key.\(rawValue)".loc }
}

struct JoinRecipe: Codable, Hashable {
    var left: PreparationSource
    var right: PreparationSource
    var leftKey: Int
    var rightKey: Int
    var mode: JoinMode = .left
    var keyMode: JoinKeyMode = .exact
    var rightColumns: [Int]
}

enum NumberConvention: String, Codable, CaseIterable, Identifiable {
    case dotDecimal, commaDecimal, arabic
    var id: String { rawValue }
    var title: String { "prep.number.\(rawValue)".loc }
}

enum PreparationDateFormat: String, Codable, CaseIterable, Identifiable {
    case iso = "yyyy-MM-dd", dayFirst = "dd/MM/yyyy", monthFirst = "MM/dd/yyyy"
    var id: String { rawValue }
}

enum CleaningOperation: String, Codable, CaseIterable, Identifiable {
    case trim, normalizeDigits, lowercase, uppercase, replaceText, fillMissing, blankToNull
    case parseNumber, parseDate, dropMissing, removeDuplicates
    var id: String { rawValue }
    var title: String { "prep.clean.\(rawValue)".loc }
    var needsColumn: Bool { self != .removeDuplicates }
}

struct CleaningStep: Codable, Hashable, Identifiable {
    var id = UUID()
    var operation: CleaningOperation
    var column: Int = 0
    var value = ""
    var replacement = ""
    var numberConvention: NumberConvention = .dotDecimal
    var dateFormat: PreparationDateFormat = .iso
}

struct CleaningRecipe: Codable, Hashable {
    var source: PreparationSource
    var steps: [CleaningStep]
}

struct PreparationRecipe: Codable, Hashable {
    enum Operation: Codable, Hashable {
        case clean(CleaningRecipe)
        case join(JoinRecipe)
    }
    var version = 1
    var operation: Operation

    var sources: [PreparationSource] {
        switch operation {
        case .clean(let recipe): return [recipe.source]
        case .join(let recipe): return [recipe.left, recipe.right]
        }
    }

    func validate() throws {
        guard version == 1 else { throw PreparationError.recipe }
        for source in sources { try source.validateStructure() }
        switch operation {
        case .clean(let recipe):
            guard recipe.steps.count <= 20 else { throw PreparationError.recipe }
            for step in recipe.steps {
                guard (!step.operation.needsColumn || recipe.source.columns.indices.contains(step.column)),
                      step.value.count <= 1000, step.replacement.count <= 1000 else { throw PreparationError.recipe }
                if step.operation == .replaceText && step.value.isEmpty { throw PreparationError.recipe }
            }
        case .join(let recipe):
            guard recipe.left.columns.indices.contains(recipe.leftKey), recipe.right.columns.indices.contains(recipe.rightKey),
                  !recipe.rightColumns.isEmpty,
                  Set(recipe.rightColumns).count == recipe.rightColumns.count,
                  recipe.rightColumns.allSatisfy({ recipe.right.columns.indices.contains($0) }),
                  recipe.left.columns.count + recipe.rightColumns.count <= PreparationLimits.columns else {
                throw PreparationError.recipe
            }
        }
    }
}

/// Undo/redo edits the recipe, never writes imported cells. Saved outputs are immutable.
struct CleaningDraft {
    private(set) var steps: [CleaningStep]
    private var undoStack: [[CleaningStep]] = []
    private var redoStack: [[CleaningStep]] = []
    init(steps: [CleaningStep] = []) { self.steps = steps }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func replace(with next: [CleaningStep]) {
        guard next != steps else { return }
        undoStack.append(steps)
        if undoStack.count > 100 { undoStack.removeFirst() }
        steps = next
        redoStack.removeAll()
    }
    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(steps); steps = previous
    }
    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(steps); steps = next
    }
}

struct JoinDiagnostics: Codable {
    let leftRows: Int
    let rightRows: Int
    let matchedLeft: Int
    let unmatchedLeft: Int
    let unmatchedRight: Int
    let blankLeftKeys: Int
    let blankRightKeys: Int
    let duplicateLeftKeys: Int
    let duplicateRightKeys: Int
    let outputRows: Int
}

struct CleaningImpact: Codable, Identifiable {
    let id: UUID
    let operation: CleaningOperation
    let columnName: String
    let changed: Int
    let removed: Int
    let invalid: Int
}

struct PreparationSummary: Codable {
    var join: JoinDiagnostics?
    var cleaning: [CleaningImpact] = []
    var outputRows = 0
}

struct PreparationPreview {
    let recipe: PreparationRecipe
    let summary: PreparationSummary
    let before: ResultTable?
    let after: ResultTable
    let rejected: ResultTable?
    let artifact: PreparedArtifact?
    let blockReason: String?

    var needsDuplicateApproval: Bool { (summary.join?.duplicateRightKeys ?? 0) > 0 }
    var needsInvalidApproval: Bool { summary.cleaning.contains { $0.invalid > 0 } }
}

/// Owns only a private temporary directory, never an imported/workspace path.
final class PreparedArtifact {
    let directory: URL
    var databaseURL: URL { directory.appendingPathComponent("prepared.sqlite") }
    let columns: [ColumnInfo]
    let rows: Int
    init(directory: URL, columns: [ColumnInfo], rows: Int) {
        self.directory = directory; self.columns = columns; self.rows = rows
    }
    deinit {
        let url = directory
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) }
    }
}

enum PreparationLimits {
    static let rows = 1_000_000
    static let columns = 128
    static let stagingBytes: Int64 = 512 * 1024 * 1024
    static let previewRows = 30
    static let seconds: TimeInterval = 120
}

enum PreparationError: LocalizedError {
    case recipe, sourceChanged, sourceLimit, outputLimit, lookupDuplicates, approveDuplicates, approveInvalid
    case storage, timeout, valueLimit
    var errorDescription: String? {
        switch self {
        case .recipe: return "prep.error.recipe".loc
        case .sourceChanged: return "prep.error.source".loc
        case .sourceLimit: return "prep.error.sourceLimit".loc
        case .outputLimit: return "prep.error.outputLimit".loc
        case .lookupDuplicates: return "prep.error.lookup".loc
        case .approveDuplicates: return "prep.error.approveDuplicates".loc
        case .approveInvalid: return "prep.error.approveInvalid".loc
        case .storage: return "prep.error.storage".loc
        case .valueLimit: return "prep.error.valueLimit".loc
        case .timeout: return "prep.error.timeout".loc
        }
    }
}

final class PreparationBudget {
    let cancellation: QueryCancellation
    private let deadline: TimeInterval
    init(cancellation: QueryCancellation, seconds: TimeInterval = PreparationLimits.seconds) {
        self.cancellation = cancellation
        deadline = ProcessInfo.processInfo.systemUptime + seconds
    }
    func check() throws {
        if cancellation.isCancelled { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw PreparationError.timeout }
    }
}
