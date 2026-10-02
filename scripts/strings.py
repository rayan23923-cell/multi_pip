#!/usr/bin/env python3
"""Single source of truth for TaskLens UI strings.

Running this script regenerates:
  Packages/TaskLensUI/Sources/TLLocalization/Resources/Localizable.xcstrings
  Packages/TaskLensUI/Sources/TLLocalization/L10nKey.swift

Add a key here (with both English and Arabic) instead of editing those files.
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOC = ROOT / "Packages/TaskLensUI/Sources/TLLocalization"

STRINGS = [
    # key, English, Arabic
    ("tab.commandCenter", "Command Center", "مركز الأوامر"),
    ("tab.workspaces", "Workspaces", "مساحات العمل"),
    ("tab.settings", "Settings", "الإعدادات"),

    ("common.cancel", "Cancel", "إلغاء"),
    ("common.create", "Create", "إنشاء"),
    ("common.delete", "Delete", "حذف"),
    ("common.ok", "OK", "حسناً"),
    ("common.save", "Save", "حفظ"),
    ("common.more", "More", "المزيد"),
    ("common.errorTitle", "Something went wrong", "حدث خطأ"),

    ("capture.placeholder", "Type or paste something…", "اكتب أو الصق شيئاً…"),
    ("capture.inbox", "Inbox", "الوارد"),

    ("commandCenter.activeSessions", "Active Sessions", "الجلسات النشطة"),
    ("commandCenter.recentItems", "Recent Items", "العناصر الأخيرة"),
    ("commandCenter.quickCapture", "Quick Capture", "التقاط سريع"),
    ("commandCenter.savesTo", "Saves to the most recent active session, or the inbox.",
     "يُحفظ في آخر جلسة نشطة، أو في الوارد."),
    ("commandCenter.empty.title", "Nothing captured yet", "لم يتم التقاط شيء بعد"),
    ("commandCenter.empty.message", "Type or paste content above to get started.",
     "اكتب أو الصق محتوى في الأعلى للبدء."),

    ("workspaces.create", "New Workspace", "مساحة عمل جديدة"),
    ("workspaces.name", "Name", "الاسم"),
    ("workspaces.color", "Color", "اللون"),
    ("workspaces.archive", "Archive", "أرشفة"),
    ("workspaces.empty.title", "No workspaces", "لا توجد مساحات عمل"),
    ("workspaces.empty.message", "Create a workspace to group your sessions.",
     "أنشئ مساحة عمل لتجميع جلساتك."),
    ("workspace.sessions", "Sessions", "الجلسات"),
    ("workspace.startSession", "Start Session", "بدء جلسة"),
    ("workspace.noSessions.title", "No sessions yet", "لا توجد جلسات بعد"),
    ("workspace.noSessions.message", "Start a session to collect what you are working on.",
     "ابدأ جلسة لتجميع ما تعمل عليه."),

    ("session.untitled", "Untitled Session", "جلسة بدون عنوان"),
    ("session.items", "Items", "العناصر"),
    ("session.noItems.title", "No items yet", "لا توجد عناصر بعد"),
    ("session.noItems.message", "Anything you capture in this session appears here.",
     "كل ما تلتقطه في هذه الجلسة يظهر هنا."),
    ("session.end", "End Session", "إنهاء الجلسة"),
    ("session.pause", "Pause", "إيقاف مؤقت"),
    ("session.resume", "Resume", "استئناف"),
    ("session.startedAt", "Started", "بدأت"),
    ("session.state.active", "Active", "نشطة"),
    ("session.state.paused", "Paused", "متوقفة مؤقتاً"),
    ("session.state.ended", "Ended", "منتهية"),
    ("session.kind.general", "General", "عامة"),
    ("session.kind.research", "Research", "بحث"),
    ("session.kind.shopping", "Shopping", "تسوق"),
    ("session.kind.study", "Study", "دراسة"),
    ("session.kind.developer", "Developer", "تطوير"),
    ("session.kind.other", "Other", "أخرى"),

    ("item.type.text", "Text", "نص"),
    ("item.type.url", "Link", "رابط"),
    ("item.type.image", "Image", "صورة"),
    ("item.type.pdf", "PDF", "PDF"),
    ("item.type.document", "Document", "مستند"),

    ("settings.about", "About", "حول"),
    ("settings.version", "Version", "الإصدار"),
    ("settings.privacy", "Privacy", "الخصوصية"),
    ("settings.privacy.body",
     "TaskLens only processes content you explicitly type, paste, share or capture. Your data stays on this device.",
     "يعالج TaskLens فقط المحتوى الذي تكتبه أو تلصقه أو تشاركه أو تلتقطه بنفسك. تبقى بياناتك على هذا الجهاز."),
    ("settings.language", "Language", "اللغة"),
    ("settings.language.body", "TaskLens follows the language chosen for it in iOS Settings.",
     "يتبع TaskLens اللغة المختارة له في إعدادات iOS."),
    ("settings.openSettings", "Open iOS Settings", "فتح إعدادات iOS"),
    ("settings.storage", "Storage", "التخزين"),
    ("settings.storage.appGroup", "Shared app container", "حاوية التطبيق المشتركة"),
    ("settings.storage.local", "Local app storage", "تخزين التطبيق المحلي"),
    ("settings.storage.memory", "Temporary, not saved", "مؤقت وغير محفوظ"),

    ("error.notFound", "This item no longer exists.", "هذا العنصر لم يعد موجوداً."),
    ("error.validation.emptyName", "Please enter a name.", "يرجى إدخال اسم."),
    ("error.validation.nameTooLong", "The name is too long.", "الاسم طويل جداً."),
    ("error.validation.emptyContent", "There is nothing to save.", "لا يوجد شيء لحفظه."),
    ("error.validation.contentTooLarge", "The content is too large.", "المحتوى كبير جداً."),
    ("error.validation.invalidURL", "The link is not valid.", "الرابط غير صالح."),
    ("error.state.sessionEnded", "This session has ended.", "انتهت هذه الجلسة."),
    ("error.state.sessionAlreadyActive", "This session is already active.", "هذه الجلسة نشطة بالفعل."),
    ("error.state.workspaceArchived", "This workspace is archived.", "مساحة العمل هذه مؤرشفة."),
    ("error.persistence", "Your data could not be saved. Please try again.",
     "تعذّر حفظ بياناتك. يرجى المحاولة مرة أخرى."),
    ("error.unsupportedContent", "This type of content is not supported yet.",
     "هذا النوع من المحتوى غير مدعوم بعد."),
    ("error.unavailable", "This feature is not available on this device.",
     "هذه الميزة غير متاحة على هذا الجهاز."),
    ("error.generic", "Please try again.", "يرجى المحاولة مرة أخرى."),
]


def case_name(key: str) -> str:
    parts = re.split(r"[.]", key)
    words = []
    for part in parts:
        words.append(part[0].upper() + part[1:])
    name = "".join(words)
    return name[0].lower() + name[1:]


def main() -> None:
    keys = [k for k, _, _ in STRINGS]
    assert len(keys) == len(set(keys)), "duplicate keys"

    catalog = {
        "sourceLanguage": "en",
        "strings": {
            key: {
                "extractionState": "manual",
                "localizations": {
                    "ar": {"stringUnit": {"state": "translated", "value": ar}},
                    "en": {"stringUnit": {"state": "translated", "value": en}},
                },
            }
            for key, en, ar in STRINGS
        },
        "version": "1.0",
    }
    (LOC / "Resources").mkdir(parents=True, exist_ok=True)
    (LOC / "Resources/Localizable.xcstrings").write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    lines = [
        "// Generated by scripts/strings.py. Do not edit by hand.",
        "",
        "/// Every user-facing string key. The catalog is `Resources/Localizable.xcstrings`.",
        "public enum L10nKey: String, CaseIterable, Sendable {",
    ]
    for key in keys:
        lines.append(f'    case {case_name(key)} = "{key}"')
    lines.append("}")
    (LOC / "L10nKey.swift").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {len(keys)} keys")


if __name__ == "__main__":
    main()
