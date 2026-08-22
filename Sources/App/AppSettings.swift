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
        "common.share": ("Share", "مشاركة")
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
    @AppStorage("headerRowDefault") var headerRowDefault: Bool = true { didSet { objectWillChange.send() } }
    @AppStorage("haptics") var haptics: Bool = true { didSet { objectWillChange.send() } }
    @AppStorage("aiProvider") var aiProviderRaw: String = AIProvider.openAI.rawValue { didSet { objectWillChange.send() } }
    @AppStorage("aiModel") var aiModel: String = "" { didSet { objectWillChange.send() } }
    @AppStorage("aiBaseURL") var aiBaseURL: String = "" { didSet { objectWillChange.send() } }

    private init() {
        L10n.language = AppLanguage(rawValue: languageRaw) ?? .ar
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: languageRaw) ?? .ar }
        set { languageRaw = newValue.rawValue; L10n.language = newValue }
    }

    var colorScheme: ColorScheme? {
        switch themeRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var aiProvider: AIProvider {
        get { AIProvider(rawValue: aiProviderRaw) ?? .openAI }
        set { aiProviderRaw = newValue.rawValue }
    }

    var apiKey: String {
        get { Keychain.get(aiProvider.keychainKey) ?? "" }
        set { Keychain.set(newValue, for: aiProvider.keychainKey); objectWillChange.send() }
    }

    var hasAI: Bool { !apiKey.isEmpty }

    var aiConfig: AIConfig {
        AIConfig(provider: aiProvider,
                 model: aiModel.isEmpty ? aiProvider.defaultModel : aiModel,
                 baseURL: aiBaseURL.isEmpty ? aiProvider.defaultBaseURL : aiBaseURL,
                 apiKey: apiKey)
    }

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard haptics else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

extension String {
    var loc: String { L10n.t(self) }
}
