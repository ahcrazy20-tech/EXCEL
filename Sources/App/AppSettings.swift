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
        "settings.aiNote": ("AI receives your question and column schema. Narration also sends report or result excerpts, which may contain cell values. Enabled fallback can send this context to another configured provider. Full files are not uploaded.",
                            "يستقبل الذكاء الاصطناعي سؤالك وأسماء الأعمدة. ويرسل التحليل السردي مقتطفات من التقرير أو النتائج قد تتضمن قيم خلايا. عند تفعيل التبديل التلقائي قد تُرسل هذه المعلومات إلى مزوّد آخر مفعّل. لا تُرفع الملفات كاملة."),
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
        "ai.retry": ("Retry", "إعادة المحاولة"),
        "ai.loadingKeys": ("Loading secure credentials…", "جارٍ تحميل المفاتيح الآمنة…"),
        "ai.saving": ("Saving securely…", "جارٍ الحفظ الآمن…"),
        "ai.keychainError": ("Secure storage is unavailable. Unlock your device and retry. If this persists, check the app’s signing and Keychain entitlements.", "التخزين الآمن غير متاح. افتح قفل الجهاز وأعد المحاولة. إذا استمرت المشكلة، تحقق من توقيع التطبيق وصلاحيات Keychain."),
        "ai.chooseModel": ("Choose a model", "اختر موديلًا"),
        "ai.searchModels": ("Search all models", "ابحث في كل الموديلات"),
        "ai.freeOnly": ("Free models only", "الموديلات المجانية فقط"),
        "ai.selectedModel": ("Selected", "المحدد"),
        "ai.noModelMatches": ("No matching models. Change the search or enter a model ID on the previous screen.", "لا توجد موديلات مطابقة. غيّر البحث أو أدخل اسم الموديل في الشاشة السابقة."),
        "ai.modelCount": ("%d of %d models", "%d من %d موديل"),
        "ai.modelsLoaded": ("%d models loaded. Open Choose a model to search them.", "تم تحميل %d موديل. افتح «اختر موديلًا» للبحث فيها."),
        "ai.modelsHint": ("Suggestions work offline. Fetch to check current availability; pricing and quotas depend on your account. You can also enter a model ID manually.", "الاقتراحات متاحة بدون إنترنت. اجلب القائمة للتحقق من التوفر الحالي؛ الأسعار والحدود تعتمد على حسابك. يمكنك إدخال اسم الموديل يدويًا."),
        "ai.noRemoteModels": ("The provider returned no compatible models. Showing suggestions.", "لم يُرجع المزوّد موديلات متوافقة. تُعرض الاقتراحات."),
        "ai.modelsFailed": ("Could not refresh models. The previous list is still available.", "تعذر تحديث الموديلات. القائمة السابقة ما زالت متاحة."),
        "ai.cancelRequest": ("Cancel request", "إلغاء الطلب"),
        "ai.testDraft": ("Tests these fields without saving. A test sends a small request and may incur provider charges.", "يختبر هذه الحقول دون حفظها. يرسل الاختبار طلبًا صغيرًا وقد يترتب عليه رسوم من المزوّد."),
        "ai.invalidURL": ("Enter a full HTTP or HTTPS API base URL without a query, fragment, username or password.", "أدخل رابط API كاملًا يبدأ بـ HTTP أو HTTPS بدون استعلام أو جزء إضافي أو اسم مستخدم أو كلمة مرور."),
        "analysis.readOnly": ("Only read-only queries against this sheet are allowed.", "يُسمح باستعلامات القراءة فقط على هذه الورقة."),
        "analysis.oneStatement": ("Run one SQL statement at a time.", "نفّذ تعليمة SQL واحدة في كل مرة."),
        "analysis.timedOut": ("This analysis exceeded its 15-second budget. Add filters or simplify the query and retry.", "تجاوز التحليل مهلة 15 ثانية. أضف فلاتر أو بسّط الاستعلام ثم أعد المحاولة."),
        "analysis.tooLarge": ("The result exceeds the memory budget. Select fewer columns, aggregate, or add filters.", "تجاوزت النتيجة حد الذاكرة. اختر أعمدة أقل أو استخدم التجميع أو أضف فلاتر."),
        "analysis.invalidPlan": ("This plan contains an invalid column, filter, or unsupported calculation. Refine your question. Grouped medians are not supported yet.", "تحتوي الخطة على عمود أو فلتر غير صالح أو عملية غير مدعومة. وضّح سؤالك. الوسيط حسب المجموعات غير مدعوم بعد."),
        "analysis.incompatible": ("This saved analysis is incompatible with the current sheet or app version. Recreate it from Ask.", "هذا التحليل المحفوظ غير متوافق مع الورقة أو إصدار التطبيق الحالي. أعد إنشاءه من «اسأل»."),
        "analysis.cancelled": ("Cancelled. Any completed result is kept.", "تم الإلغاء. تُحفظ أي نتيجة مكتملة."),
        "analysis.saved": ("Saved Analyses", "التحليلات المحفوظة"),
        "analysis.savedHint": ("Reusable analyses for this sheet. Open one to review its question, then Run to replay the saved plan locally.", "تحليلات قابلة لإعادة الاستخدام لهذه الورقة. افتح تحليلًا لمراجعة سؤاله ثم اضغط «تنفيذ» لإعادة تشغيل الخطة محليًا."),
        "analysis.empty": ("Your analysis library starts here", "ابدأ مكتبة تحليلاتك هنا"),
        "analysis.emptyHint": ("Run a question in Ask, then choose Save analysis. Your filters, grouping and calculations are saved, not just the question.", "نفّذ سؤالًا في «اسأل»، ثم اختر «حفظ التحليل». تُحفظ الفلاتر والتجميعات والحسابات، وليس السؤال فقط."),
        "analysis.latest": ("Showing the latest 200 saved analyses for this sheet. Rename or delete with a swipe or a long press.", "تُعرض أحدث 200 تحليل محفوظ لهذه الورقة. لإعادة التسمية أو الحذف اسحب العنصر أو اضغط مطولًا."),
        "analysis.save": ("Save analysis", "حفظ التحليل"),
        "analysis.name": ("Analysis name (up to 120 characters)", "اسم التحليل (حتى 120 حرفًا)"),
        "analysis.saveHint": ("Save this exact plan and source schema for offline reuse. This does not copy the source data.", "احفظ هذه الخطة ومخطط المصدر لإعادة الاستخدام دون إنترنت. لا يؤدي ذلك إلى نسخ بيانات المصدر."),
        "analysis.savedOK": ("Saved in this sheet’s analysis library", "حُفظ في مكتبة تحليلات هذه الورقة"),
        "analysis.replay": ("Saved plan · runs locally without AI. Edit the question to start a new analysis.", "خطة محفوظة · تعمل محليًا دون ذكاء اصطناعي. عدّل السؤال لبدء تحليل جديد."),
        "analysis.narrate": ("AI narrative (share result excerpts)", "تحليل سردي بالذكاء الاصطناعي (مشاركة مقتطفات النتائج)"),
        "analysis.localResult": ("Computed locally", "محسوب محليًا"),
        "analysis.elapsed": ("Local query: %.2fs", "الاستعلام المحلي: %.2f ثانية"),
        "analysis.previewRows": ("%d of %d loaded rows", "%d من %d صف محمّل"),
        "analysis.truncated": ("Limited preview — not the complete result. Export and report contain only the loaded preview. Filter or aggregate for a complete answer.", "معاينة محدودة — ليست النتيجة الكاملة. يتضمن التصدير والتقرير المعاينة المحمّلة فقط. استخدم الفلاتر أو التجميع للحصول على إجابة كاملة."),
        "overview.title": ("Data Overview", "نظرة عامة على البيانات"),
        "overview.filtered": ("Scope: current search and filters", "النطاق: البحث والفلاتر الحالية"),
        "overview.allRows": ("Scope: the entire sheet", "النطاق: الورقة كاملة"),
        "overview.local": ("On-device analysis. No data is sent to an AI provider.", "تحليل على الجهاز. لا تُرسل أي بيانات إلى مزوّد ذكاء اصطناعي."),
        "overview.progress": ("Profiling columns: %d of %d", "تحليل الأعمدة: %d من %d"),
        "overview.refresh": ("Refresh overview", "تحديث النظرة العامة"),
        "overview.matchingRows": ("Matching rows (exact)", "الصفوف المطابقة (عدد دقيق)"),
        "overview.profiledRows": ("Rows profiled", "الصفوف المحلّلة"),
        "overview.completeness": ("Cell completeness", "اكتمال الخلايا"),
        "overview.sampled": ("Sampled column profiles", "ملفات أعمدة مبنية على عينة"),
        "overview.exact": ("All matching rows profiled", "تم تحليل جميع الصفوف المطابقة"),
        "overview.quality": ("Data quality", "جودة البيانات"),
        "overview.sampleNote": ("Column metrics use the first 10,000 matching rows in source order, or all matches when fewer. The row count is exact. Blank values include NULL and space-only text. Numeric metrics use stored numbers only; text is never treated as zero.", "تعتمد مقاييس الأعمدة على أول 10 آلاف صف مطابق بترتيب المصدر، أو كل الصفوف إن كانت أقل. عدد الصفوف دقيق. تشمل القيم الفارغة NULL والنص المكوّن من مسافات. تُحسب المقاييس الرقمية من الأرقام المخزّنة فقط؛ لا يُعامل النص كصفر."),
        "overview.missing": ("Missing in profiled rows", "القيم المفقودة في الصفوف المحلّلة"),
        "overview.distinct": ("Distinct non-empty values", "القيم المختلفة غير الفارغة"),
        "overview.average": ("Average", "المتوسط"),
        "overview.minimum": ("Minimum", "الأدنى"),
        "overview.maximum": ("Maximum", "الأعلى"),
        "overview.invalidNumbers": ("%d non-empty values are not stored as numbers; excluded from numeric metrics.", "%d قيمة غير فارغة ليست مخزّنة كأرقام؛ استُبعدت من المقاييس الرقمية."),
        "overview.showMissing": ("Show missing across entire sheet", "عرض القيم المفقودة في الورقة كاملة"),
        "overview.missingScope": ("Replaces current filters and search. The grid may include more missing rows than this profile sample.", "يستبدل الفلاتر والبحث الحاليين. قد يعرض الجدول صفوفًا مفقودة أكثر من هذه العينة."),
        "files.deleteSheet": ("Delete sheet", "حذف الورقة"),
        "files.deleteWorkbook": ("Delete entire workbook", "حذف الملف بكل أوراقه"),
        "files.workbookActions": ("Workbook actions", "إجراءات الملف"),
        "files.confirmDelete": ("Confirm deletion", "تأكيد الحذف"),
        "files.deleteSheetMessage": ("Delete “%@” and its local data, reports and saved analyses? Other sheets and the original file will not be changed. If this is the last sheet, its empty workbook is removed too. This cannot be undone.", "هل تريد حذف «%@» وبياناتها المحلية وتقاريرها وتحليلاتها المحفوظة؟ لن تتغير الأوراق الأخرى أو الملف الأصلي. إذا كانت آخر ورقة، يُحذف الملف الفارغ من المكتبة أيضًا. لا يمكن التراجع عن الحذف."),
        "files.deleteWorkbookMessage": ("Delete “%@” and all %d sheets, including their local data, reports and saved analyses? The original file is unchanged. This cannot be undone.", "هل تريد حذف «%@» وكل أوراقه (%d) مع بياناتها المحلية وتقاريرها وتحليلاتها المحفوظة؟ لن يتغير الملف الأصلي. لا يمكن التراجع عن الحذف."),
        "files.storageBusy": ("Please wait for the current import or deletion to finish.", "يرجى الانتظار حتى تنتهي عملية الاستيراد أو الحذف الحالية."),
        "files.sheetChanged": ("This sheet is no longer available or its stored identity has changed. Refresh the library and try again.", "هذه الورقة لم تعد متاحة أو تغيرت هويتها المخزنة. حدّث المكتبة وأعد المحاولة."),
        "files.deleting": ("Deleting local data…", "جارٍ حذف البيانات المحلية…"),
        "ask.options": ("Ask options", "خيارات السؤال"),
        "ask.readFull": ("Read full text", "قراءة النص كاملًا"),
        "result.expand": ("Explore result", "استعراض النتيجة"),
        "result.rows": ("Rows", "الصفوف"),
        "result.columns": ("Columns", "الأعمدة"),
        "result.range": ("%@: %d–%d of %d", "%@: %d–%d من %d"),
        "result.page": ("%d / %d", "%d / %d"),
        "result.previous": ("Previous", "السابق"),
        "result.next": ("Next", "التالي"),
        "result.copyFull": ("Copy full text", "نسخ النص كاملًا"),
        "result.navigationHint": ("Scroll inside the table. Use the arrows for more rows or columns; tap a cell to read or copy its full value. Pages cover the loaded result only.", "مرّر داخل الجدول. استخدم الأسهم لعرض المزيد من الصفوف أو الأعمدة، واضغط على خلية لقراءة قيمتها كاملة أو نسخها. تشمل الصفحات النتيجة المحمّلة فقط."),
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

    @Published private var apiKeys: [AIProvider: String] = [:]
    @Published private(set) var apiKeysLoaded = false
    @Published private(set) var apiKeyLoadError: String?
    private let credentialStorage: AICredentialStorage
    private var credentialLoadTask: Task<Void, Error>?

    init(credentialStorage: AICredentialStorage = KeychainCredentialStorage()) {
        self.credentialStorage = credentialStorage
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

    /// Pure memory reads: safe to call repeatedly from SwiftUI body computations.
    func apiKey(for provider: AIProvider) -> String { apiKeys[provider] ?? "" }

    func hasKey(_ provider: AIProvider) -> Bool { !apiKey(for: provider).isEmpty }

    @MainActor
    func loadAPIKeys() async throws {
        guard !apiKeysLoaded else { return }
        if let task = credentialLoadTask {
            try await task.value
            return
        }
        let storage = credentialStorage
        let task = Task { @MainActor in
            defer { credentialLoadTask = nil }
            do {
                apiKeys = try await storage.load()
                apiKeysLoaded = true
                apiKeyLoadError = nil
            } catch {
                apiKeyLoadError = error.localizedDescription
                throw error
            }
        }
        credentialLoadTask = task
        try await task.value
    }

    @MainActor
    func setAPIKey(_ key: String, for provider: AIProvider) async throws {
        try await loadAPIKeys()
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try await credentialStorage.set(value, for: provider)
        // Publish only after Security confirms persistence; failed writes keep the old key.
        apiKeys[provider] = value
    }

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
