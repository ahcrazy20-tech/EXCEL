import Foundation
import SwiftUI
import UIKit

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case en, ar
    var id: String { rawValue }
    var display: String { self == .ar ? "العربية" : "English" }
    var isRTL: Bool { self == .ar }
    var layoutDirection: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }
}

/// Lightweight in-code localisation so the bundle needs no .strings files.
enum L10n {
    static var language: AppLanguage = .ar

    static func t(_ key: String) -> String {
        guard let pair = table[key] else { return key }
        return language == .ar ? pair.1 : pair.0
    }

    private static let table: [String: (String, String)] = [
        "app.name": ("SheetX", "SheetX"),
        "tab.files": ("Files", "الملفات"),
        "tab.reports": ("Reports", "التقارير"),
        "tab.settings": ("Settings", "الإعدادات"),

        "files.title": ("My Sheets", "ملفاتي"),
        "files.empty.title": ("No files yet", "لا توجد ملفات بعد"),
        "files.empty.body": ("Import an Excel, CSV or JSON file to get started. Files are indexed locally for instant search.",
                             "استورد ملف Excel أو CSV أو JSON للبدء. تتم فهرسة الملفات محليًا للبحث الفوري."),
        "files.import": ("Import file", "استيراد ملف"),
        "files.importing": ("Importing…", "جارٍ الاستيراد…"),
        "files.rows": ("rows", "صف"),
        "files.sheets": ("sheets", "أوراق"),
        "files.delete": ("Delete", "حذف"),
        "files.headerRow": ("First row is a header", "الصف الأول عناوين"),
        "files.headerMode": ("Header row", "صف العناوين"),
        "files.headerMode.auto": ("Auto-detect", "كشف تلقائي"),
        "files.headerMode.always": ("First row", "الصف الأول"),
        "files.headerMode.none": ("No header", "بدون عناوين"),
        "files.headerMode.hint": ("Auto-detect finds the header row by itself — even under report titles or blank rows — and never treats it as data.",
                                  "الكشف التلقائي يحدد صف العناوين بنفسه حتى لو كان تحت عنوان تقرير أو صفوف فارغة، ولا يعامله كبيانات أبدًا."),
        "files.sample": ("Load demo data", "تحميل بيانات تجريبية"),

        "sheet.search": ("Search all columns", "ابحث في كل الأعمدة"),
        "sheet.rows": ("rows", "صف"),
        "sheet.filtered": ("filtered", "بعد الفلترة"),
        "sheet.filters": ("Filters", "الفلاتر"),
        "sheet.sort": ("Sort", "الترتيب"),
        "sheet.columns": ("Columns", "الأعمدة"),
        "sheet.stats": ("Stats", "إحصاءات"),
        "sheet.ask": ("Ask", "اسأل"),
        "sheet.chart": ("Charts", "الرسوم"),
        "sheet.export": ("Export", "تصدير"),
        "sheet.freeze": ("Freeze first column", "تثبيت العمود الأول"),
        "sheet.pivot": ("Pivot table", "جدول محوري"),
        "sheet.goto": ("Go to row", "اذهب إلى صف"),
        "sheet.clear": ("Clear", "مسح"),
        "sheet.apply": ("Apply", "تطبيق"),
        "sheet.addFilter": ("Add filter", "أضف فلتر"),
        "sheet.matchAll": ("Match all", "كل الشروط"),
        "sheet.matchAny": ("Match any", "أي شرط"),
        "sheet.noResults": ("No matching rows", "لا توجد نتائج"),
        "sheet.row": ("Row", "صف"),
        "sheet.copy": ("Copy", "نسخ"),
        "sheet.details": ("Row details", "تفاصيل الصف"),
        "sheet.hide": ("Hide", "إخفاء"),
        "sheet.show": ("Show", "إظهار"),
        "sheet.pin": ("Pin", "تثبيت"),
        "sheet.index": ("Create index (faster)", "إنشاء فهرس (أسرع)"),

        "ask.title": ("Ask your data", "اسأل بياناتك"),
        "ask.placeholder": ("e.g. Sum of Amount by City", "مثال: مجموع المبلغ حسب المدينة"),
        "ask.run": ("Run", "تنفيذ"),
        "ask.offline": ("Offline engine", "المحرك المحلي"),
        "ask.ai": ("AI", "الذكاء الاصطناعي"),
        "ask.thinking": ("Working…", "جارٍ التنفيذ…"),
        "ask.plan": ("Plan", "الخطة"),
        "ask.result": ("Result", "النتيجة"),
        "ask.makeReport": ("Create report", "أنشئ تقرير"),
        "ask.suggestions": ("Try", "جرّب"),
        "ask.rowsShown": ("rows shown", "صف معروض"),
        "ask.saveResult": ("Save as report", "حفظ كتقرير"),
        "ask.applyToSheet": ("Apply to sheet", "طبّق على الجدول"),

        "pivot.rows": ("Rows", "الصفوف"),
        "pivot.rows2": ("Level 2", "مستوى 2"),
        "pivot.columns": ("Columns", "الأعمدة"),
        "pivot.metric": ("Value", "القيمة"),
        "pivot.none": ("None", "بدون"),
        "pivot.run": ("Build", "أنشئ"),
        "pivot.total": ("Total", "الإجمالي"),
        "pivot.limit": ("Top", "الأعلى"),
        "pivot.csv": ("CSV", "CSV"),
        "pivot.cap": ("Very high cardinality — showing an approximation", "تعدد قيم مرتفع جدًا — العرض تقريبي"),
        "pivot.hint": ("Pick one or two row dimensions, an optional column dimension and a value, then press Build. Tap any cell to filter the sheet by it.",
                       "اختر بُعد صف أو اثنين، وبُعد أعمدة اختياريًا، وقيمة، ثم اضغط أنشئ. اضغط على أي خلية لتفلتر الشيت بها."),
        "export.coloredGrid": ("Colored table instead of report", "جدول ملون بدل التقرير"),

        "report.title": ("Reports", "التقارير"),
        "report.empty": ("Reports you generate will appear here.", "التقارير التي تنشئها ستظهر هنا."),
        "report.generate": ("Generate full report", "إنشاء تقرير كامل"),
        "report.share": ("Share", "مشاركة"),
        "report.pdf": ("PDF", "PDF"),
        "report.delete": ("Delete", "حذف"),
        "report.aiNarrative": ("AI narrative", "تحليل بالذكاء الاصطناعي"),

        "settings.title": ("Settings", "الإعدادات"),
        "settings.language": ("Language", "اللغة"),
        "settings.appearance": ("Appearance", "المظهر"),
        "settings.theme.system": ("System", "النظام"),
        "settings.theme.light": ("Light", "فاتح"),
        "settings.theme.dark": ("Dark", "داكن"),
        "settings.ai": ("AI provider", "مزوّد الذكاء الاصطناعي"),
        "settings.provider": ("Provider", "المزوّد"),
        "settings.model": ("Model", "الموديل"),
        "settings.baseURL": ("Base URL", "رابط الـ API"),
        "settings.apiKey": ("API key", "مفتاح الـ API"),
        "settings.save": ("Save", "حفظ"),
        "settings.test": ("Test connection", "اختبار الاتصال"),
        "settings.aiNote": ("Only the column schema and computed statistics are sent — never the raw file.",
                            "يتم إرسال أسماء الأعمدة والإحصاءات المحسوبة فقط — لا يتم إرسال الملف نفسه أبدًا."),
        "settings.grid": ("Grid", "الجدول"),
        "settings.rowHeight": ("Row height", "ارتفاع الصف"),
        "settings.fontSize": ("Font size", "حجم الخط"),
        "settings.colWidth": ("Column width", "عرض العمود"),
        "settings.cellColors": ("Cell colors", "ألوان الخلايا"),
        "settings.importColors": ("Import Excel cell colors", "استيراد ألوان خلايا Excel"),
        "settings.showColors": ("Show colors inside the grid", "إظهار الألوان داخل الجدول"),
        "settings.storage": ("Storage", "التخزين"),
        "settings.dbSize": ("Database size", "حجم قاعدة البيانات"),
        "settings.clearAll": ("Delete all data", "حذف كل البيانات"),
        "settings.about": ("About", "حول"),
        "settings.haptics": ("Haptics", "الاهتزاز"),

        "common.cancel": ("Cancel", "إلغاء"),
        "common.done": ("Done", "تم"),
        "common.close": ("Close", "إغلاق"),
        "common.error": ("Error", "خطأ"),
        "common.ok": ("OK", "حسناً"),
        "common.all": ("All", "الكل"),
        "common.none": ("None", "لا شيء"),
        "common.loading": ("Loading…", "جارٍ التحميل…"),
        "common.delete": ("Delete", "حذف"),
        "common.rename": ("Rename", "إعادة تسمية"),
        "common.count": ("Count", "العدد"),
        "common.value": ("Value", "القيمة"),
        "common.column": ("Column", "العمود"),
        "common.share": ("Share", "مشاركة"),

        "ai.free": ("Free providers", "مزوّدون مجانيون"),
        "ai.other": ("Other providers", "مزوّدون آخرون"),
        "ai.freeBadge": ("FREE", "مجاني"),
        "ai.primary": ("Primary", "أساسي"),
        "ai.none": ("Not configured", "غير مفعّل"),
        "ai.active": ("Order", "ترتيب المحاولة"),
        "ai.fallback": ("Auto fallback", "تبديل تلقائي عند الفشل"),
        "ai.fallback.note": ("If a provider fails or hits its rate limit, the next configured provider is tried automatically.",
                             "لو مزوّد فشل أو وصل حد الاستخدام، يتم تجربة المزوّد التالي تلقائيًا."),
        "ai.freeHint": ("Groq, Gemini, Cerebras, Mistral, OpenRouter and GitHub Models all offer free keys with no credit card.",
                        "Groq و Gemini و Cerebras و Mistral و OpenRouter و GitHub Models كلها توفّر مفاتيح مجانية بدون بطاقة."),
        "ai.getKey": ("Get a free API key", "احصل على مفتاح مجاني"),
        "ai.removeKey": ("Remove key", "حذف المفتاح"),
        "ai.fetchModels": ("Fetch available models", "جلب الموديلات المتاحة"),
        "ai.testOK": ("Connection works", "الاتصال ناجح"),
        "ai.testFail": ("Connection failed", "فشل الاتصال"),
        "ai.makePrimary": ("Set as primary provider", "اجعله المزوّد الأساسي"),
        "ai.usedProvider": ("Answered by", "تمت الإجابة عبر")
    ]
}

/// Global user settings, persisted in UserDefaults (secrets go to the Keychain).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("language") var languageRaw: String = "ar" {
        didSet { L10n.language = language; objectWillChange.send() }
    }
    @AppStorage("theme") var themeRaw: String = "system" { didSet { objectWillChange.send() } }
    @AppStorage("rowHeight") var rowHeight: Double = 34 { didSet { objectWillChange.send() } }
    @AppStorage("fontSize") var fontSize: Double = 13 { didSet { objectWillChange.send() } }
    @AppStorage("columnWidth") var columnWidth: Double = 130 { didSet { objectWillChange.send() } }
    @AppStorage("freezeFirstColumn") var freezeFirstColumn: Bool = true { didSet { objectWillChange.send() } }
    @AppStorage("headerModeRaw") var headerModeRaw: String = HeaderMode.auto.rawValue {
        didSet { objectWillChange.send() }
    }
    @AppStorage("importCellColors") var importCellColors: Bool = true { didSet { objectWillChange.send() } }
    @AppStorage("showCellColors") var showCellColors: Bool = true { didSet { objectWillChange.send() } }
    @AppStorage("haptics") var haptics: Bool = true { didSet { objectWillChange.send() } }
    @AppStorage("aiProvider") var aiProviderRaw: String = AIProvider.groq.rawValue { didSet { objectWillChange.send() } }
    @AppStorage("aiModelsJSON") var aiModelsJSON: String = "{}" { didSet { objectWillChange.send() } }
    @AppStorage("aiBaseURLsJSON") var aiBaseURLsJSON: String = "{}" { didSet { objectWillChange.send() } }
    @AppStorage("aiFallback") var aiFallbackEnabled: Bool = true { didSet { objectWillChange.send() } }

    private init() {
        L10n.language = AppLanguage(rawValue: languageRaw) ?? .ar
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: languageRaw) ?? .ar }
        set { languageRaw = newValue.rawValue; L10n.language = newValue }
    }

    var headerMode: HeaderMode {
        get { HeaderMode(rawValue: headerModeRaw) ?? .auto }
        set { headerModeRaw = newValue.rawValue }
    }

    var colorScheme: ColorScheme? {
        switch themeRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var aiProvider: AIProvider {
        get { AIProvider(rawValue: aiProviderRaw) ?? .groq }
        set { aiProviderRaw = newValue.rawValue; objectWillChange.send() }
    }

    // MARK: Per-provider keys, models and endpoints

    func apiKey(for provider: AIProvider) -> String {
        Keychain.get(provider.keychainKey) ?? ""
    }

    func setAPIKey(_ key: String, for provider: AIProvider) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.keychainKey)
        objectWillChange.send()
    }

    func hasKey(_ provider: AIProvider) -> Bool { !apiKey(for: provider).isEmpty }

    private func dictionary(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }

    private func encode(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func model(for provider: AIProvider) -> String {
        let stored = dictionary(aiModelsJSON)[provider.rawValue] ?? ""
        return stored.isEmpty ? provider.defaultModel : stored
    }

    func setModel(_ model: String, for provider: AIProvider) {
        var dict = dictionary(aiModelsJSON)
        dict[provider.rawValue] = model.trimmingCharacters(in: .whitespacesAndNewlines)
        aiModelsJSON = encode(dict)
    }

    func baseURL(for provider: AIProvider) -> String {
        let stored = dictionary(aiBaseURLsJSON)[provider.rawValue] ?? ""
        return stored.isEmpty ? provider.defaultBaseURL : stored
    }

    func setBaseURL(_ url: String, for provider: AIProvider) {
        var dict = dictionary(aiBaseURLsJSON)
        dict[provider.rawValue] = url.trimmingCharacters(in: .whitespacesAndNewlines)
        aiBaseURLsJSON = encode(dict)
    }

    func config(for provider: AIProvider) -> AIConfig {
        AIConfig(provider: provider,
                 model: model(for: provider),
                 baseURL: baseURL(for: provider),
                 apiKey: apiKey(for: provider))
    }

    /// Every provider that is ready to be used, primary first (used for automatic fallback).
    var configuredProviders: [AIProvider] {
        var list: [AIProvider] = []
        if hasKey(aiProvider) || (aiProvider == .custom && !baseURL(for: .custom).isEmpty) {
            list.append(aiProvider)
        }
        for p in AIProvider.ordered where p != aiProvider {
            if hasKey(p) || (p == .custom && !baseURL(for: .custom).isEmpty && hasKey(.custom)) {
                list.append(p)
            }
        }
        return list
    }

    var hasAI: Bool { !configuredProviders.isEmpty }

    var aiConfig: AIConfig { config(for: aiProvider) }

    /// Router that tries the primary provider then the rest (when fallback is on).
    var aiRouter: AIRouter {
        let providers = aiFallbackEnabled ? configuredProviders : Array(configuredProviders.prefix(1))
        return AIRouter(configs: providers.map { config(for: $0) })
    }

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard haptics else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

extension String {
    var loc: String { L10n.t(self) }
}
