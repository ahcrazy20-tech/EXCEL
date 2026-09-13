import Foundation
import SQLite3

/// Strict conversions: failure is nil, never numeric zero or a guessed date.
enum CleanValueRules {
    static func isMissing(_ value: DBValue) -> Bool {
        switch value {
        case .null: return true
        case .text(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    static func digits(_ text: String) -> String {
        let arabic = Array("٠١٢٣٤٥٦٧٨٩"), persian = Array("۰۱۲۳۴۵۶۷۸۹"), latin = Array("0123456789")
        return String(text.map { character in
            if let index = arabic.firstIndex(of: character) { return latin[index] }
            if let index = persian.firstIndex(of: character) { return latin[index] }
            return character
        })
    }

    private static let patterns: [NumberConvention: NSRegularExpression] = {
        var result: [NumberConvention: NSRegularExpression] = [:]
        for format in NumberConvention.allCases {
            let group = format == .dotDecimal ? "," : (format == .commaDecimal ? "." : "٬")
            let decimal = format == .dotDecimal ? "." : (format == .commaDecimal ? "," : "٫")
            let g = NSRegularExpression.escapedPattern(for: group), d = NSRegularExpression.escapedPattern(for: decimal)
            result[format] = try! NSRegularExpression(pattern: "^[+-]?(?:[0-9]+|[0-9]{1,3}(?:\(g)[0-9]{3})+)(?:\(d)[0-9]+)?(?:[eE][+-]?[0-9]+)?$")
        }
        return result
    }()

    static func number(_ value: DBValue, convention: NumberConvention) -> DBValue? {
        switch value {
        case .int: return value
        case .double(let number): return number.isFinite ? value : nil
        case .null: return nil
        case .text(let raw):
            let text = digits(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard patterns[convention]?.firstMatch(in: text, range: range)?.range == range else { return nil }
            let group = convention == .dotDecimal ? "," : (convention == .commaDecimal ? "." : "٬")
            let decimal = convention == .dotDecimal ? "." : (convention == .commaDecimal ? "," : "٫")
            let canonical = text.replacingOccurrences(of: group, with: "").replacingOccurrences(of: decimal, with: ".")
            if !canonical.contains("."), !canonical.lowercased().contains("e") {
                // Never silently round an oversized integral identifier into a Double.
                return Int64(canonical).map { .int($0) }
            }
            let mantissa = canonical.lowercased().split(separator: "e").first ?? ""
            let significant = mantissa.filter(\.isNumber).drop(while: { $0 == "0" }).count
            guard significant <= 15, let number = Double(canonical), number.isFinite,
                  number != 0 || significant == 0 else { return nil }
            return .double(number)
        }
    }
}

/// Registered only on trusted preparation connections, not in the AI SQL sandbox.
final class PreparationFunctions {
    private var dateReaders: [PreparationDateFormat: DateFormatter] = [:]
    private let iso = PreparationFunctions.formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = format
        return formatter
    }

    func date(_ value: DBValue, format: PreparationDateFormat) -> DBValue? {
        guard case .text(let raw) = value else { return nil }
        let text = CleanValueRules.digits(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 10 else { return nil }
        let reader: DateFormatter
        if let cached = dateReaders[format] { reader = cached }
        else { reader = Self.formatter(format.rawValue); dateReaders[format] = reader }
        guard let date = reader.date(from: text), reader.string(from: date) == text else { return nil }
        return .text(iso.string(from: date))
    }

    func apply(_ value: DBValue, operation: String, first: String, second: String) -> DBValue {
        if operation == "blank" { return .int(CleanValueRules.isMissing(value) ? 1 : 0) }
        if operation == "key" {
            guard case .text(let text) = value else { return value }
            return .text(CleanValueRules.digits(text).trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping.lowercased())
        }
        guard let operation = CleaningOperation(rawValue: operation) else { return value }
        switch operation {
        case .fillMissing: return CleanValueRules.isMissing(value) ? .text(first) : value
        case .blankToNull: return CleanValueRules.isMissing(value) ? .null : value
        case .parseNumber: return CleanValueRules.number(value, convention: NumberConvention(rawValue: first) ?? .dotDecimal) ?? .null
        case .parseDate: return date(value, format: PreparationDateFormat(rawValue: first) ?? .iso) ?? .null
        case .trim, .normalizeDigits, .lowercase, .uppercase, .replaceText:
            guard case .text(let text) = value else { return value }
            switch operation {
            case .trim: return .text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .normalizeDigits: return .text(CleanValueRules.digits(text))
            case .lowercase: return .text(text.lowercased())
            case .uppercase: return .text(text.uppercased())
            default: return .text(text.replacingOccurrences(of: first, with: second))
            }
        default: return value
        }
    }

    static func install(on handle: OpaquePointer?) throws {
        let context = Unmanaged.passRetained(PreparationFunctions()).toOpaque()
        let rc = sqlite3_create_function_v2(handle, "sx_clean", 4, SQLITE_UTF8 | SQLITE_DETERMINISTIC, context,
            { context, count, arguments in
                guard let context, count == 4, let arguments, let user = sqlite3_user_data(context) else { return }
                let functions = Unmanaged<PreparationFunctions>.fromOpaque(user).takeUnretainedValue()
                let value = PreparationFunctions.read(arguments[0])
                let operation = PreparationFunctions.read(arguments[1]).stringValue
                let first = PreparationFunctions.read(arguments[2]).stringValue, second = PreparationFunctions.read(arguments[3]).stringValue
                PreparationFunctions.write(functions.apply(value, operation: operation, first: first, second: second), to: context)
            }, nil, nil, { pointer in
                if let pointer { Unmanaged<PreparationFunctions>.fromOpaque(pointer).release() }
            })
        guard rc == SQLITE_OK else { throw DBError.exec("Cannot register preparation functions") }
    }

    private static func read(_ value: OpaquePointer?) -> DBValue {
        switch sqlite3_value_type(value) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .int(sqlite3_value_int64(value))
        case SQLITE_FLOAT: return .double(sqlite3_value_double(value))
        default:
            guard let text = sqlite3_value_text(value) else { return .null }
            let buffer = UnsafeBufferPointer(start: text, count: Int(sqlite3_value_bytes(value)))
            return .text(String(decoding: buffer, as: UTF8.self))
        }
    }

    private static func write(_ value: DBValue, to context: OpaquePointer?) {
        switch value {
        case .null: sqlite3_result_null(context)
        case .int(let number): sqlite3_result_int64(context, number)
        case .double(let number): sqlite3_result_double(context, number)
        case .text(let text): sqlite3_result_text(context, text, Int32(text.utf8.count), SQLITE_TRANSIENT_HANDLE)
        }
    }
}
