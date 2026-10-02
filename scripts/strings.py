#!/usr/bin/env python3
"""Single source of truth for TaskLens UI strings.

Running this script regenerates:
  Packages/TaskLensUI/Sources/TLLocalization/Resources/Localizable.xcstrings
  Packages/TaskLensUI/Sources/TLLocalization/L10nKey.swift
  App/TaskLens/Resources/Localizable.xcstrings   (App Intents metadata)
  App/TaskLens/Resources/AppShortcuts.xcstrings  (App Shortcut phrases)

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
    ("session.state.archived", "Archived", "مؤرشفة"),
    ("session.favorite", "Add to Favorites", "إضافة إلى المفضلة"),
    ("session.unfavorite", "Remove from Favorites", "إزالة من المفضلة"),
    ("session.archive", "Archive", "أرشفة"),
    ("session.unarchive", "Unarchive", "إلغاء الأرشفة"),
    ("session.rename", "Rename", "إعادة تسمية"),
    ("session.name", "Session name", "اسم الجلسة"),
    ("session.delete", "Delete Session", "حذف الجلسة"),
    ("session.deleteMessage", "The session, its items and its action history will be deleted. Notes stay in Notes.",
     "ستُحذف الجلسة وعناصرها وسجل إجراءاتها. تبقى الملاحظات في الملاحظات."),
    ("session.favorites", "Favorites", "المفضلة"),
    ("session.archived", "Archived", "المؤرشفة"),
    ("session.lastActivity", "Last activity", "آخر نشاط"),
    ("session.pickUp", "Pick Up Where You Left Off", "تابع من حيث توقفت"),
    ("session.pickUpNote", "This restores your TaskLens session only. Other apps open as they are.",
     "يستعيد هذا جلسة TaskLens فقط. التطبيقات الأخرى تفتح كما هي."),
    ("session.resume.page", "Open the last web page", "افتح آخر صفحة ويب"),
    ("session.resume.document", "Open the document at page %lld", "افتح المستند عند الصفحة %lld"),
    ("session.resume.note", "Open the last note", "افتح آخر ملاحظة"),
    ("session.resume.tool", "Open the last tool", "افتح آخر أداة"),
    ("session.sort", "Sort", "الترتيب"),
    ("session.sort.recent", "Recent", "الأحدث"),
    ("session.sort.type", "Type", "النوع"),
    ("session.sort.importance", "Importance", "الأهمية"),
    ("session.searchPrompt", "Search this session", "ابحث في هذه الجلسة"),
    ("session.actionHistory", "Action History", "سجل الإجراءات"),
    ("session.markImportant", "Mark as Important", "تمييز كمهم"),
    ("session.unmarkImportant", "Remove Important Mark", "إزالة تمييز الأهمية"),
    ("session.important", "Important", "مهم"),
    ("session.itemKind.note", "Notes", "ملاحظات"),
    ("session.itemKind.link", "Links", "روابط"),
    ("session.itemKind.document", "Documents", "مستندات"),
    ("session.itemKind.image", "Images", "صور"),
    ("session.itemKind.calculation", "Calculations", "حسابات"),
    ("session.itemKind.code", "Code", "شيفرة"),
    ("session.itemKind.question", "Questions", "أسئلة"),
    ("session.itemKind.clipboard", "Clipboard", "الحافظة"),
    ("session.itemKind.text", "Text", "نصوص"),
    ("actionRecord.completed", "Done", "تم"),
    ("actionRecord.handedOff", "Opened", "فُتح"),
    ("actionRecord.failed", "Failed", "فشل"),
    # Widgets and Siri
    ("widget.name", "TaskLens", "TaskLens"),
    ("widget.description", "Quick actions, recent sessions and your workspace.", "إجراءات سريعة وآخر الجلسات ومساحة عملك."),
    ("widget.recentSessions", "Recent Sessions", "آخر الجلسات"),
    ("widget.noSessions", "No sessions yet. Start one in TaskLens.", "لا توجد جلسات بعد. ابدأ واحدة في TaskLens."),
    ("widget.noWorkspaces", "Open TaskLens to create a workspace.", "افتح TaskLens لإنشاء مساحة عمل."),
    ("widget.itemCount", "%lld items", "%lld عناصر"),

    # Live Activity and Dynamic Island.
    ("activity.sessionTitle", "%@ Session", "جلسة %@"),
    ("activity.links", "Links: %lld", "الروابط: %lld"),
    ("activity.notes", "Notes: %lld", "الملاحظات: %lld"),
    ("activity.documents", "Documents: %lld", "المستندات: %lld"),
    ("activity.items", "Items: %lld", "العناصر: %lld"),
    ("activity.processing", "Processing", "قيد المعالجة"),
    ("activity.focus", "Focus", "تركيز"),
    ("activity.task", "Active Task", "المهمة الحالية"),
    ("activity.elapsed", "Elapsed", "المدة"),
    ("activity.remaining", "Remaining", "المتبقي"),
    ("activity.resume", "Resume", "استئناف"),
    ("activity.stop", "Stop", "إيقاف"),
    ("activity.stale", "No recent activity", "لا يوجد نشاط حديث"),
    ("session.focus", "Focus Timer", "مؤقت التركيز"),
    ("session.focus.minutes", "%lld minutes", "%lld دقيقة"),
    ("session.focus.stop", "Stop Focus Timer", "إيقاف مؤقت التركيز"),

    # What Siri and Shortcuts say back after an action.
    ("intent.result.savedToSession", "Saved to %@.", "تم الحفظ في %@."),
    ("intent.result.savedToInbox", "Saved to the inbox.", "تم الحفظ في الوارد."),
    ("intent.result.noteCreated", "Note created: %@", "تم إنشاء الملاحظة: %@"),
    ("intent.result.equals", "%@ = %@", "%@ = %@"),
    # Picture in Picture
    ("pip.title", "Picture in Picture", "صورة داخل صورة"),
    ("pip.keep", "Keep in Picture in Picture", "إبقاء في صورة داخل صورة"),
    ("pip.page", "Page %lld", "صفحة %lld"),
    ("pip.emptyCard", "Add a note, a page or a result to keep it in view.", "أضف ملاحظة أو صفحة أو نتيجة لتبقى أمامك."),
    ("pip.kind.note", "Note", "ملاحظة"),
    ("pip.kind.document", "Document", "مستند"),
    ("pip.kind.calculation", "Calculation", "عملية حسابية"),
    ("pip.kind.context", "Context", "سياق"),
    ("pip.status", "Window", "النافذة"),
    ("pip.status.idle", "Closed", "مغلقة"),
    ("pip.status.unavailable", "Not available right now", "غير متاحة الآن"),
    ("pip.status.starting", "Opening…", "جارٍ الفتح…"),
    ("pip.status.active", "Showing", "معروضة"),
    ("pip.status.stopping", "Closing…", "جارٍ الإغلاق…"),
    ("pip.start", "Start Picture in Picture", "بدء صورة داخل صورة"),
    ("pip.stop", "Stop Picture in Picture", "إيقاف صورة داخل صورة"),
    ("pip.previous", "Previous Card", "البطاقة السابقة"),
    ("pip.next", "Next Card", "البطاقة التالية"),
    ("pip.showing", "Showing", "معروضة"),
    ("pip.cards", "Cards", "البطاقات"),
    ("pip.cards.hint", "Use Keep in Picture in Picture from a note, a document page, the calculator or a session item. Tap a card to show it.", "استخدم «إبقاء في صورة داخل صورة» من ملاحظة أو صفحة مستند أو الحاسبة أو عنصر جلسة. اضغط بطاقة لعرضها."),
    ("pip.noCards", "No cards yet", "لا توجد بطاقات بعد"),
    ("pip.unsupported.title", "Not supported on this device", "غير مدعومة على هذا الجهاز"),
    ("pip.unsupported.message", "This device does not offer Picture in Picture. Your cards stay here in TaskLens.", "هذا الجهاز لا يوفر صورة داخل صورة. تبقى بطاقاتك هنا داخل TaskLens."),
    ("pip.limits.title", "What Picture in Picture can do", "ما الذي تستطيعه صورة داخل صورة"),
    ("pip.limit.readOnly", "The window shows one card as a picture. You can move it, resize it, hide it at the edge and tap it to return here. You cannot type or tap inside it; change cards here and the window follows.", "تعرض النافذة بطاقة واحدة كصورة. يمكنك تحريكها وتغيير حجمها وإخفاءها عند الحافة والضغط عليها للعودة. لا يمكن الكتابة أو الضغط داخلها؛ غيّر البطاقة من هنا وستتبعها النافذة."),
    ("pip.limit.ownContent", "It shows TaskLens content only. It cannot place controls over other apps or read what they show.", "تعرض محتوى TaskLens فقط. لا يمكنها وضع عناصر تحكم فوق التطبيقات الأخرى أو قراءة ما تعرضه."),
    ("pip.limit.start", "iOS opens it only from TaskLens: when you tap Start, or when you leave the app while this screen is open (if automatic Picture in Picture is on in Settings).", "يفتحها iOS من داخل TaskLens فقط: عند الضغط على «بدء»، أو عند مغادرة التطبيق وهذه الشاشة مفتوحة (إذا كانت صورة داخل صورة التلقائية مفعّلة في الإعدادات)."),
    ("pip.limit.closed", "It closes when TaskLens is closed, and iOS may close it for a call or another video. Your cards are kept.", "تُغلق عند إغلاق TaskLens، وقد يغلقها iOS بسبب مكالمة أو فيديو آخر. بطاقاتك محفوظة."),
    ("pip.stopped.user", "Picture in Picture was closed.", "أُغلقت صورة داخل صورة."),
    ("pip.stopped.restored", "Returned from Picture in Picture.", "تمت العودة من صورة داخل صورة."),
    ("pip.stopped.interrupted", "iOS closed Picture in Picture for a call or other audio. Start it again when you are ready.", "أغلق iOS صورة داخل صورة بسبب مكالمة أو صوت آخر. ابدأها مجدداً عندما تكون جاهزاً."),
    ("pip.stopped.failed", "Picture in Picture could not open. Another app may be using it.", "تعذّر فتح صورة داخل صورة. ربما يستخدمها تطبيق آخر."),
    ("pip.stopped.appClosed", "Picture in Picture ended when TaskLens was closed. Your cards are still here.", "انتهت صورة داخل صورة عند إغلاق TaskLens. بطاقاتك ما زالت هنا."),

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

    ("common.edit", "Edit", "تعديل"),
    ("common.duplicate", "Duplicate", "تكرار"),
    ("common.favorite", "Add to Favorites", "إضافة إلى المفضلة"),
    ("common.unfavorite", "Remove from Favorites", "إزالة من المفضلة"),
    ("common.done", "Done", "تم"),

    ("commandCenter.quickActions", "Quick Actions", "إجراءات سريعة"),
    ("commandCenter.seeAll", "See All", "عرض الكل"),
    ("commandCenter.recentSessions", "Recent Sessions", "الجلسات الأخيرة"),
    ("commandCenter.searchPrompt", "Search workspaces, sessions and items",
     "ابحث في مساحات العمل والجلسات والعناصر"),
    ("commandCenter.noWorkspaces", "Create your first workspace to organize your work.",
     "أنشئ أول مساحة عمل لتنظيم عملك."),

    ("workspaces.favorites", "Favorites", "المفضلة"),
    ("workspaces.recent", "Recently Opened", "المفتوحة مؤخراً"),
    ("workspace.kind.study", "Study", "دراسة"),
    ("workspace.kind.work", "Work", "عمل"),
    ("workspace.kind.shopping", "Shopping", "تسوق"),
    ("workspace.kind.developer", "Developer", "تطوير"),
    ("workspace.kind.custom", "Custom", "مخصصة"),
    ("workspace.kind.research", "Research", "بحث"),
    ("workspace.tools", "Tools", "الأدوات"),
    ("workspace.tool.notes", "Notes", "الملاحظات"),
    ("workspace.tool.calculator", "Calculator", "الآلة الحاسبة"),
    ("workspace.tool.browser", "Browser", "المتصفح"),
    ("workspace.tool.documents", "Documents", "المستندات"),
    ("workspace.tool.clipboard", "Clipboard", "الحافظة"),
    ("workspace.tool.lens", "Lens", "العدسة"),
    ("workspace.tool.other", "Tool", "أداة"),
    ("workspace.tool.upcoming", "Available in a later update", "متاحة في تحديث لاحق"),
    ("workspace.lastOpened", "Last opened", "آخر فتح"),
    ("workspace.neverOpened", "Not opened yet", "لم تُفتح بعد"),
    ("workspace.copyName", "%@ Copy", "نسخة من %@"),
    ("workspace.delete.title", "Delete this workspace?", "حذف مساحة العمل هذه؟"),
    ("workspace.delete.message", "Its sessions, items and notes will also be deleted. This cannot be undone.",
     "ستُحذف أيضاً جلساتها وعناصرها وملاحظاتها. لا يمكن التراجع عن ذلك."),
    ("workspaceEditor.editTitle", "Edit Workspace", "تعديل مساحة العمل"),
    ("workspaceEditor.kind", "Type", "النوع"),
    ("workspaceEditor.icon", "Icon", "الأيقونة"),
    ("workspaceEditor.settings", "Workspace Settings", "إعدادات مساحة العمل"),
    ("workspaceEditor.defaultSessionKind", "Default session type", "نوع الجلسة الافتراضي"),
    ("workspaceEditor.resumesLastSession", "Resume last session when opened", "استئناف آخر جلسة عند الفتح"),

    ("lens.title", "Lens", "العدسة"),
    ("lens.subtitle", "Understand text and links", "افهم النصوص والروابط"),
    ("lens.placeholder", "Paste or type text, a number or a link", "الصق أو اكتب نصاً أو رقماً أو رابطاً"),
    ("lens.input", "Content", "المحتوى"),
    ("lens.detectedType", "Detected type", "النوع المكتشف"),
    ("lens.detectedContent", "Detected Content", "المحتوى المكتشف"),
    ("lens.actions", "Actions", "الإجراءات"),
    ("lens.saved", "Saved", "تم الحفظ"),

    ("clipboard.title", "Clipboard", "الحافظة"),
    ("clipboard.subtitle", "Paste to keep what you copied", "الصق للاحتفاظ بما نسخته"),
    ("clipboard.history", "History", "السجل"),
    ("clipboard.empty.title", "Nothing pasted yet", "لم يُلصق شيء بعد"),
    ("clipboard.empty.message", "Tap Paste to bring in what you copied. TaskLens never reads your clipboard on its own.",
     "اضغط لصق لإحضار ما نسخته. لا يقرأ TaskLens الحافظة من تلقاء نفسه."),
    ("clipboard.clear", "Clear History", "مسح السجل"),
    ("clipboard.saved", "Saved to TaskLens", "محفوظ في TaskLens"),

    ("action.copy", "Copy", "نسخ"),
    ("action.share", "Share", "مشاركة"),
    ("action.saveToSession", "Save", "حفظ"),
    ("action.openURL", "Open Link", "فتح الرابط"),

    # Phase 4: tools
    ("common.close", "Close", "إغلاق"),
    ("common.saved", "Saved", "تم الحفظ"),
    ("common.saveToSession", "Save to Session", "حفظ في الجلسة"),
    ("common.copied", "Copied", "تم النسخ"),
    ("common.matchCount", "Matches: %lld", "النتائج: %lld"),

    ("notes.new", "New Note", "ملاحظة جديدة"),
    ("notes.edit", "Edit Note", "تعديل الملاحظة"),
    ("notes.titlePlaceholder", "Title", "العنوان"),
    ("notes.bodyPlaceholder", "Write your note", "اكتب ملاحظتك"),
    ("notes.searchPrompt", "Search notes", "ابحث في الملاحظات"),
    ("notes.empty.title", "No notes yet", "لا توجد ملاحظات بعد"),
    ("notes.empty.message", "Tap + to write your first note.", "اضغط + لكتابة أول ملاحظة."),
    ("notes.pin", "Pin", "تثبيت"),
    ("notes.unpin", "Unpin", "إلغاء التثبيت"),
    ("notes.pinned", "Pinned", "مثبتة"),
    ("notes.attach", "Attach to Session", "إرفاق بجلسة"),
    ("notes.attached", "Attached to session", "أُرفقت بالجلسة"),
    ("notes.noSessions", "Start a session in a workspace to attach notes to it.",
     "ابدأ جلسة في مساحة عمل لإرفاق الملاحظات بها."),
    ("notes.untitled", "Untitled Note", "ملاحظة بدون عنوان"),
    ("notes.delete.title", "Delete this note?", "حذف هذه الملاحظة؟"),

    ("calculator.history", "History", "السجل"),
    ("calculator.history.empty", "Calculations you finish appear here.", "تظهر هنا العمليات التي تنهيها."),
    ("calculator.clearHistory", "Clear History", "مسح السجل"),
    ("calculator.copyResult", "Copy Result", "نسخ النتيجة"),
    ("calculator.sendToActions", "Send to Actions", "إرسال إلى الإجراءات"),
    ("calculator.useResult", "Use Result", "استخدام النتيجة"),
    ("calculator.error", "Cannot divide by zero", "لا يمكن القسمة على صفر"),
    ("calculator.key.add", "Plus", "زائد"),
    ("calculator.key.subtract", "Minus", "ناقص"),
    ("calculator.key.multiply", "Multiply", "ضرب"),
    ("calculator.key.divide", "Divide", "قسمة"),
    ("calculator.key.percent", "Percent", "نسبة مئوية"),
    ("calculator.key.equals", "Equals", "يساوي"),
    ("calculator.key.clear", "Clear", "مسح"),
    ("calculator.key.backspace", "Delete digit", "حذف رقم"),
    ("calculator.key.toggleSign", "Change sign", "تغيير الإشارة"),
    ("calculator.key.decimal", "Decimal point", "فاصلة عشرية"),

    ("browser.address", "Address", "العنوان"),
    ("browser.addressPrompt", "Enter a website address", "أدخل عنوان موقع"),
    ("browser.back", "Back", "رجوع"),
    ("browser.forward", "Forward", "تقدم"),
    ("browser.reload", "Reload", "إعادة التحميل"),
    ("browser.stop", "Stop", "إيقاف"),
    ("browser.tabs", "Tabs", "علامات التبويب"),
    ("browser.newTab", "New Tab", "علامة تبويب جديدة"),
    ("browser.closeTab", "Close Tab", "إغلاق علامة التبويب"),
    ("browser.empty.title", "Enter an address to start", "أدخل عنواناً للبدء"),
    ("browser.empty.message",
     "Pages open in a private session. Cookies and website data are cleared when TaskLens closes.",
     "تُفتح الصفحات في جلسة خاصة. تُمسح ملفات تعريف الارتباط وبيانات المواقع عند إغلاق TaskLens."),
    ("browser.saveURL", "Save Link to Session", "حفظ الرابط في الجلسة"),

    ("documents.import", "Import", "استيراد"),
    ("documents.importFiles", "From Files", "من الملفات"),
    ("documents.importPhotos", "From Photos", "من الصور"),
    ("documents.empty.title", "No documents", "لا توجد مستندات"),
    ("documents.empty.message", "Import a PDF, image or text file. It stays on this device.",
     "استورد ملف PDF أو صورة أو ملفاً نصياً. يبقى على هذا الجهاز."),
    ("documents.delete.title", "Delete this document?", "حذف هذا المستند؟"),
    ("documents.delete.message", "The copy stored in TaskLens will be removed.",
     "ستُحذف النسخة المحفوظة في TaskLens."),
    ("documents.openFailed", "This file could not be opened.", "تعذّر فتح هذا الملف."),

    ("pdf.page", "Page %lld of %lld", "صفحة %lld من %lld"),
    ("pdf.previousPage", "Previous Page", "الصفحة السابقة"),
    ("pdf.nextPage", "Next Page", "الصفحة التالية"),
    ("pdf.goToPage", "Go to Page", "الانتقال إلى صفحة"),
    ("pdf.searchPrompt", "Search in document", "ابحث في المستند"),
    ("pdf.matchPosition", "%lld of %lld", "%lld من %lld"),
    ("pdf.noMatches", "No matches", "لا توجد نتائج"),
    ("pdf.previousMatch", "Previous Match", "النتيجة السابقة"),
    ("pdf.nextMatch", "Next Match", "النتيجة التالية"),
    ("pdf.extractText", "Extract Page Text", "استخراج نص الصفحة"),
    ("pdf.extractedText", "Page Text", "نص الصفحة"),
    ("pdf.noText", "This page has no selectable text. Text recognition (OCR) will be added in a later update.",
     "لا تحتوي هذه الصفحة على نص قابل للتحديد. سيُضاف التعرف على النص (OCR) في تحديث لاحق."),
    ("pdf.saveText", "Save Text to Session", "حفظ النص في الجلسة"),

    ("image.recognizeText", "Recognize Text", "التعرف على النص"),
    ("image.ocrLater", "Text recognition (OCR) will be added in a later update.",
     "سيُضاف التعرف على النص (OCR) في تحديث لاحق."),
    ("image.resetZoom", "Reset Zoom", "إعادة ضبط التكبير"),

    ("text.searchPrompt", "Search in text", "ابحث في النص"),
    ("text.truncated", "Only the beginning of this file is shown.", "يُعرض جزء من بداية هذا الملف فقط."),
    ("text.copyAll", "Copy All", "نسخ الكل"),
    ("text.fontSize", "Text Size", "حجم النص"),
    ("text.monospaced", "Monospaced", "خط ثابت العرض"),
    ("text.saveText", "Save Text to Session", "حفظ النص في الجلسة"),

    # Phase 5: Context Engine, Action Engine, Smart Clipboard, Share Extension
    ("common.details", "Details", "التفاصيل"),

    ("category.plainText", "Text", "نص"),
    ("category.url", "Link", "رابط"),
    ("category.phone", "Phone Number", "رقم هاتف"),
    ("category.email", "Email Address", "بريد إلكتروني"),
    ("category.currency", "Amount of Money", "مبلغ مالي"),
    ("category.number", "Number", "رقم"),
    ("category.date", "Date", "تاريخ"),
    ("category.address", "Address", "عنوان"),
    ("category.json", "JSON", "JSON"),
    ("category.code", "Code", "شيفرة برمجية"),
    ("category.image", "Image", "صورة"),
    ("category.pdf", "PDF", "PDF"),
    ("category.document", "Document", "مستند"),
    ("category.unknown", "Unknown", "غير معروف"),

    ("action.call", "Call", "اتصال"),
    ("action.sendMessage", "Message", "رسالة"),
    ("action.sendEmail", "Email", "بريد إلكتروني"),
    ("action.addContact", "Add Contact", "إضافة جهة اتصال"),
    ("action.addToCalendar", "Create Calendar Event", "إنشاء حدث في التقويم"),
    ("action.openInMaps", "Open in Maps", "فتح في الخرائط"),
    ("action.calculate", "Calculate", "حساب"),
    ("action.convertCurrency", "Convert Currency", "تحويل العملة"),
    ("action.extractText", "Extract", "استخراج"),
    ("action.translate", "Translate", "ترجمة"),
    ("action.summarize", "Summarize", "تلخيص"),
    ("action.createReminder", "Create Reminder", "إنشاء تذكير"),
    ("action.createNote", "Create Note", "إنشاء ملاحظة"),
    ("action.search", "Search", "بحث"),
    ("action.askAI", "Ask AI", "اسأل الذكاء الاصطناعي"),

    ("actions.later", "Later", "لاحقاً"),
    ("actions.comingLater", "This action will be added in a later update.",
     "سيُضاف هذا الإجراء في تحديث لاحق."),
    ("actions.openApp", "Open TaskLens to do this. Save the item first, then use it from the app.",
     "افتح TaskLens لتنفيذ ذلك. احفظ العنصر أولاً ثم استخدمه من التطبيق."),
    ("actions.unavailable", "This action is not available for this content.",
     "هذا الإجراء غير متاح لهذا المحتوى."),
    ("actions.translateUnavailable", "Translation needs iOS 17.4 or later.",
     "تتطلب الترجمة iOS 17.4 أو أحدث."),
    ("actions.found", "Found in Content", "ما تم العثور عليه"),
    ("actions.inApp", "In App", "في التطبيق"),
    ("actions.recommended", "Recommended", "مقترحة"),
    ("actions.other", "More Actions", "إجراءات أخرى"),
    ("actions.showLess", "Show Less", "عرض أقل"),
    ("analysis.value", "Value", "القيمة"),
    ("analysis.confidence.high", "High confidence", "ثقة عالية"),
    ("analysis.confidence.medium", "Medium confidence", "ثقة متوسطة"),
    ("analysis.confidence.low", "Low confidence", "ثقة منخفضة"),

    ("lens.preview", "Preview", "معاينة"),

    ("clipboard.newContent", "You copied something new. Tap Paste to bring it in.",
     "نسخت شيئاً جديداً. اضغط لصق لإحضاره."),
    ("clipboard.privacyNote", "iOS asks before any app reads what you copied. TaskLens reads it only when you tap Paste.",
     "يسأل iOS قبل أن يقرأ أي تطبيق ما نسخته. يقرأه TaskLens فقط عندما تضغط لصق."),

    ("share.title", "TaskLens", "TaskLens"),
    ("share.loading", "Preparing items…", "جارٍ تجهيز العناصر…"),
    ("share.items", "Shared Items", "العناصر المشتركة"),
    ("share.destination", "Save To", "الحفظ في"),
    ("share.inbox", "Inbox", "الوارد"),
    ("share.save", "Save to Session", "حفظ في الجلسة"),
    ("share.saved", "Saved. It will appear in TaskLens the next time you open it.",
     "تم الحفظ. سيظهر في TaskLens عند فتحه في المرة القادمة."),
    ("share.nothingSupported", "None of these items can be saved.", "لا يمكن حفظ أي من هذه العناصر."),
    ("share.unsupported", "Not Supported", "غير مدعوم"),
    ("share.unsupported.type", "TaskLens can't open this type of item.", "لا يستطيع TaskLens فتح هذا النوع من العناصر."),
    ("share.unsupported.tooLarge", "This item is too large.", "هذا العنصر كبير جداً."),
    ("share.unsupported.unreadable", "This item couldn't be read.", "تعذّرت قراءة هذا العنصر."),
    ("share.unsupported.tooMany", "Only the first 10 items can be saved at once.",
     "يمكن حفظ أول 10 عناصر فقط في المرة الواحدة."),
    ("share.saveFailed", "The items could not be saved. Please try again.", "تعذّر حفظ العناصر. يرجى المحاولة مرة أخرى."),
    ("share.received", "Saved %lld shared items.", "تم حفظ %lld من العناصر المشتركة."),

    ("error.notFound", "This item no longer exists.", "هذا العنصر لم يعد موجوداً."),
    ("error.validation.emptyName", "Please enter a name.", "يرجى إدخال اسم."),
    ("error.validation.nameTooLong", "The name is too long.", "الاسم طويل جداً."),
    ("error.validation.emptyContent", "There is nothing to save.", "لا يوجد شيء لحفظه."),
    ("error.validation.contentTooLarge", "The content is too large.", "المحتوى كبير جداً."),
    ("error.validation.invalidURL", "The link is not valid.", "الرابط غير صالح."),
    ("error.validation.invalidExpression", "That is not a calculation TaskLens can do.", "هذه ليست عملية حسابية يستطيع TaskLens تنفيذها."),
    ("error.validation.outOfRange", "That value is out of range.", "هذه القيمة خارج النطاق المسموح."),
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


# App Intents metadata (titles, parameters, enum cases). The system reads these
# from the app's own catalog: App/TaskLens/Resources/Localizable.xcstrings.
APP_INTENT_STRINGS = [
    ("intent.startWorkspace.title", "Start Workspace", "بدء مساحة عمل"),
    ("intent.startWorkspace.description", "Opens your most recent workspace of a kind, or creates one.",
     "يفتح آخر مساحة عمل من نوع معيّن، أو ينشئ واحدة."),
    ("intent.openWorkspace.title", "Open Workspace", "فتح مساحة عمل"),
    ("intent.openWorkspace.description", "Opens a workspace in TaskLens.", "يفتح مساحة عمل في TaskLens."),
    ("intent.startSession.title", "Start Session", "بدء جلسة"),
    ("intent.startSession.description", "Starts a session in a workspace and opens it.", "يبدأ جلسة في مساحة عمل ويفتحها."),
    ("intent.openSession.title", "Open Session", "فتح جلسة"),
    ("intent.openSession.description", "Opens a session and continues where you stopped.", "يفتح جلسة ويتابع من حيث توقفت."),
    ("intent.saveContent.title", "Save Content", "حفظ محتوى"),
    ("intent.saveContent.description", "Saves text or a link to a session, or to the inbox when no session is active.",
     "يحفظ نصاً أو رابطاً في جلسة، أو في الوارد إذا لم تكن هناك جلسة نشطة."),
    ("intent.saveToSession.title", "Save to Session", "حفظ في جلسة"),
    ("intent.saveToSession.description", "Saves text or a link to your latest open session of a kind, starting one if needed.",
     "يحفظ نصاً أو رابطاً في آخر جلسة مفتوحة من نوع معيّن، ويبدأ جلسة إذا لزم."),
    ("intent.sendToTaskLens.title", "Send to TaskLens", "إرسال إلى TaskLens"),
    ("intent.sendToTaskLens.description", "Opens text or a link in Lens to see what you can do with it.",
     "يفتح نصاً أو رابطاً في العدسة لترى ما يمكنك فعله به."),
    ("intent.startLens.title", "Start Lens", "بدء العدسة"),
    ("intent.startLens.description", "Opens Lens to analyze text or a link.", "يفتح العدسة لتحليل نص أو رابط."),
    ("intent.openClipboard.title", "Open Clipboard", "فتح الحافظة"),
    ("intent.openClipboard.description", "Opens the TaskLens clipboard history.", "يفتح سجل حافظة TaskLens."),
    ("intent.createNote.title", "Create Note", "إنشاء ملاحظة"),
    ("intent.createNote.description", "Creates a note. With several lines, the first line is the title.",
     "ينشئ ملاحظة. إذا كانت عدة أسطر، يكون السطر الأول هو العنوان."),
    ("intent.calculate.title", "Calculate", "حساب"),
    ("intent.calculate.description", "Calculates an expression such as 12 × 3 + 4 on your device.",
     "يحسب عملية مثل 12 × 3 + 4 على جهازك."),
    ("intent.convertCurrency.title", "Convert Currency", "تحويل عملة"),
    ("intent.convertCurrency.description", "Multiplies an amount by the exchange rate you give. TaskLens does not download exchange rates.",
     "يضرب المبلغ في سعر الصرف الذي تحدده. لا يقوم TaskLens بتنزيل أسعار الصرف."),
    ("intent.stopSession.title", "Stop Session", "إيقاف الجلسة"),
    ("intent.stopSession.description", "Ends a TaskLens session and its Live Activity.", "ينهي جلسة TaskLens ونشاطها المباشر."),
    ("intent.param.sessionID", "Session ID", "معرّف الجلسة"),
    ("intent.openDestination.title", "Open in TaskLens", "فتح في TaskLens"),

    ("intent.param.workspaceKind", "Workspace Kind", "نوع مساحة العمل"),
    ("intent.param.sessionKind", "Session Kind", "نوع الجلسة"),
    ("intent.param.workspace", "Workspace", "مساحة العمل"),
    ("intent.param.session", "Session", "الجلسة"),
    ("intent.param.text", "Text", "النص"),
    ("intent.param.expression", "Expression", "العملية"),
    ("intent.param.amount", "Amount", "المبلغ"),
    ("intent.param.rate", "Exchange Rate", "سعر الصرف"),
    ("intent.param.currency", "Target Currency Code", "رمز العملة الهدف"),
    ("intent.param.destination", "Destination", "الوجهة"),

    ("intent.prompt.text", "What should TaskLens save?", "ما الذي تريد حفظه في TaskLens؟"),
    ("intent.prompt.lensText", "What should TaskLens look at?", "ما الذي تريد أن يحلله TaskLens؟"),
    ("intent.prompt.note", "What should the note say?", "ماذا تريد أن تكتب في الملاحظة؟"),
    ("intent.prompt.expression", "What should TaskLens calculate?", "ما العملية التي تريد حسابها؟"),
    ("intent.prompt.amount", "What amount?", "ما المبلغ؟"),
    ("intent.prompt.rate", "What exchange rate?", "ما سعر الصرف؟"),
    ("intent.prompt.workspace", "Which workspace?", "أي مساحة عمل؟"),
    ("intent.prompt.session", "Which session?", "أي جلسة؟"),

    ("intent.type.workspace", "Workspace", "مساحة عمل"),
    ("intent.type.session", "Session", "جلسة"),
    ("intent.type.workspaceKind", "Workspace Kind", "نوع مساحة العمل"),
    ("intent.type.sessionKind", "Session Kind", "نوع الجلسة"),
    ("intent.type.destination", "TaskLens Tool", "أداة TaskLens"),

    ("intent.workspaceKind.study", "Study", "دراسة"),
    ("intent.workspaceKind.research", "Research", "بحث"),
    ("intent.workspaceKind.work", "Work", "عمل"),
    ("intent.workspaceKind.shopping", "Shopping", "تسوق"),
    ("intent.workspaceKind.developer", "Developer", "تطوير"),
    ("intent.sessionKind.general", "General", "عامة"),
    ("intent.sessionKind.research", "Research", "بحث"),
    ("intent.sessionKind.shopping", "Shopping", "تسوق"),
    ("intent.sessionKind.study", "Study", "دراسة"),
    ("intent.sessionKind.developer", "Developer", "تطوير"),
    ("intent.destination.lens", "Lens", "العدسة"),
    ("intent.destination.clipboard", "Clipboard", "الحافظة"),
    ("intent.destination.notes", "Notes", "الملاحظات"),
    ("intent.destination.calculator", "Calculator", "الحاسبة"),
]

# App Shortcut phrases. The English phrase is written in TaskLensShortcuts.swift
# and is the key; every phrase must name the app.
APP_SHORTCUT_PHRASES = [
    ("Send to ${applicationName}", "أرسل إلى ${applicationName}"),
    ("Analyze with ${applicationName}", "حلّل باستخدام ${applicationName}"),
    ("Start ${kind} workspace in ${applicationName}", "ابدأ مساحة ${kind} في ${applicationName}"),
    ("Start a workspace in ${applicationName}", "ابدأ مساحة عمل في ${applicationName}"),
    ("Save to ${sessionKind} session in ${applicationName}", "احفظ في جلسة ${sessionKind} في ${applicationName}"),
    ("Save to ${applicationName}", "احفظ في ${applicationName}"),
    ("Save to a session in ${applicationName}", "احفظ في جلسة في ${applicationName}"),
    ("Start ${applicationName} Lens", "ابدأ عدسة ${applicationName}"),
    ("Open Lens in ${applicationName}", "افتح العدسة في ${applicationName}"),
    ("Create ${applicationName} note", "أنشئ ملاحظة في ${applicationName}"),
    ("New note in ${applicationName}", "ملاحظة جديدة في ${applicationName}"),
    ("Open ${applicationName} clipboard", "افتح حافظة ${applicationName}"),
    ("Calculate with ${applicationName}", "احسب باستخدام ${applicationName}"),
    ("Open a session in ${applicationName}", "افتح جلسة في ${applicationName}"),
    ("Start a ${applicationName} session", "ابدأ جلسة في ${applicationName}"),
]

APP_RESOURCES = ROOT / "App/TaskLens/Resources"


def write_catalog(path, entries):
    catalog = {"sourceLanguage": "en", "strings": entries, "version": "1.0"}
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_app_catalogs() -> None:
    keys = [k for k, _, _ in APP_INTENT_STRINGS]
    assert len(keys) == len(set(keys)), "duplicate app intent keys"
    write_catalog(APP_RESOURCES / "Localizable.xcstrings", {
        key: {
            "extractionState": "manual",
            "localizations": {
                "ar": {"stringUnit": {"state": "translated", "value": ar}},
                "en": {"stringUnit": {"state": "translated", "value": en}},
            },
        }
        for key, en, ar in APP_INTENT_STRINGS
    })
    phrases = [en for en, _ in APP_SHORTCUT_PHRASES]
    assert len(phrases) == len(set(phrases)), "duplicate phrases"
    assert all("${applicationName}" in en and "${applicationName}" in ar for en, ar in APP_SHORTCUT_PHRASES)
    write_catalog(APP_RESOURCES / "AppShortcuts.xcstrings", {
        en: {
            "extractionState": "manual",
            "localizations": {
                "ar": {"stringUnit": {"state": "translated", "value": ar}},
                "en": {"stringUnit": {"state": "translated", "value": en}},
            },
        }
        for en, ar in APP_SHORTCUT_PHRASES
    })


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
    write_app_catalogs()
    print(f"Wrote {len(keys)} keys, {len(APP_INTENT_STRINGS)} intent strings, {len(APP_SHORTCUT_PHRASES)} phrases")


if __name__ == "__main__":
    main()
