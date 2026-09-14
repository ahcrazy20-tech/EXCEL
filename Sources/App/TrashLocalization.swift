import Foundation

enum TrashLocalization {
    static let table: [String: (String, String)] = [
        "trash.title": ("Trash", "سلة المحذوفات"),
        "trash.move": ("Move to Trash", "نقل إلى السلة"),
        "trash.restore": ("Restore", "استعادة"),
        "trash.permanent": ("Delete permanently", "حذف نهائي"),
        "trash.empty": ("Trash is empty", "السلة فارغة"),
        "trash.working": ("Updating Trash…", "جارٍ تحديث السلة…"),
        "trash.restored": ("Sheet restored to its original workbook in My Sheets.", "تمت استعادة الورقة في مصنفها الأصلي ضمن ملفاتي."),
        "trash.deleted": ("Sheet permanently deleted.", "حُذفت الورقة نهائيًا."),
        "trash.hint": ("Restore sheets with their data, colors, reports, saved analyses, dashboards, preparation history and layout. Restoring one sheet also makes its original workbook visible again. Sheets stay here until you explicitly delete them permanently; there is no automatic expiry.", "استعد الأوراق ببياناتها وألوانها وتقاريرها وتحليلاتها ولوحاتها وسجل تجهيزها وتخطيطها. استعادة ورقة تُظهر مصنفها الأصلي مجددًا. تبقى الأوراق هنا حتى تحذفها نهائيًا بنفسك؛ لا يوجد حذف تلقائي."),
        "trash.storageHint": ("Trash still uses device storage. This is not a backup: deleting the app removes both active data and Trash. Sheets permanently deleted in older versions cannot be recovered here. Permanent deletion makes SQLite pages reusable; the database file may not shrink immediately. Restore/delete actions work on individual sheets, even when a whole workbook was moved.", "السلة تستخدم مساحة الجهاز وليست نسخة احتياطية؛ حذف التطبيق يزيل البيانات النشطة والسلة معًا. لا يمكن استعادة ما حُذف نهائيًا في الإصدارات السابقة. الحذف النهائي يتيح إعادة استخدام صفحات SQLite وقد لا يقل حجم الملف فورًا. الاستعادة والحذف لكل ورقة على حدة حتى لو نُقل المصنف كاملًا."),
        "trash.permanentMessage": ("Permanently delete “%@”, its data, colors, reports, saved analyses, dashboard, preparation history and layout? This cannot be undone. Other sheets, independent derived outputs, and your original imported file are not deleted.", "حذف «%@» وبياناتها وألوانها وتقاريرها وتحليلاتها ولوحتها وسجلها وتخطيطها نهائيًا؟ لا يمكن التراجع. لن تُحذف الأوراق الأخرى أو النتائج المشتقة المستقلة أو الملف الأصلي."),
        "trash.allMessage": ("Move all currently active sheets to Trash? Their data and saved work are retained and can be restored. Existing Trash entries are unchanged. This does not free storage; permanent deletion is a separate action inside Trash.", "نقل كل الأوراق النشطة حاليًا إلى السلة؟ تبقى البيانات والأعمال المحفوظة ويمكن استعادتها. لا تتغير العناصر الموجودة في السلة. هذا لا يحرر مساحة؛ الحذف النهائي إجراء مستقل داخل السلة."),
        "trash.stale": ("This Trash entry changed or was already restored/deleted. Refresh Trash and select it again.", "تغير هذا العنصر أو استُعيد أو حُذف بالفعل. حدّث السلة ثم اختره مجددًا."),
        "trash.restoreFirst": ("This sheet is in Trash. Restore it before running analyses, dashboards or preparation recipes.", "هذه الورقة في السلة. استعدها قبل تشغيل التحليلات أو اللوحات أو وصفات التجهيز."),
        "trash.damaged": ("The sheet's catalog or data table is missing or inconsistent. Nothing was changed. Reimport the original file if needed.", "كتالوج الورقة أو جدول بياناتها مفقود أو غير متسق. لم يتغير شيء. أعد استيراد الملف الأصلي عند الحاجة."),
        "trash.refreshNeeded": ("The Trash action completed, but the library could not refresh. Pull to refresh My Sheets and Trash; do not repeat a permanent-delete action.", "اكتمل إجراء السلة، لكن تعذر تحديث المكتبة. اسحب لتحديث ملفاتي والسلة؛ لا تكرر الحذف النهائي."),
    ]
}
