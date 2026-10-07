# TaskLens — Phase 1: Repository Audit

التاريخ: 2026-10-02 04:13 UTC
المستودع: `rayan23923-cell/multi_pip`
لم يُعدَّل أي كود. لا يوجد ما يستدعي إصلاح build.

## طريقة الفحص (أُعيد عند بداية هذه المرحلة)
- `git fetch` + `git ls-remote origin`: لا refs على الإطلاق.
- GitHub API `list_branches`: `[]`.
- GitHub API `get_file_contents /`: `409 Git Repository is empty`.
- مجلد العمل المحلي: يحتوي `.git` فقط.
- ملفات المشروع المشتركة: لا يوجد سوى تقرير Phase 0.

---

## PROJECT STATUS

**المستودع فارغ تماماً (0 commits، 0 branches، 0 files).** لا يوجد مشروع iOS لتدقيقه.

| البند | النتيجة |
|---|---|
| Xcode project / workspace | غير موجود (لا `.xcodeproj` ولا `.xcworkspace` ولا `Package.swift` ولا `project.yml`) |
| App targets | لا يوجد |
| Extensions | لا يوجد |
| Swift version | غير محدد |
| iOS deployment target | غير محدد |
| SwiftUI / UIKit usage | لا يوجد كود |
| Package dependencies | لا يوجد (لا SPM، لا CocoaPods، لا Carthage) |
| Existing services | لا يوجد |
| Existing persistence | لا يوجد |
| Existing navigation | لا يوجد |
| Existing tests | لا يوجد |
| Existing CI / build scripts | لا يوجد (لا `.github/workflows`، لا Fastlane، لا Makefile) |

---

## ARCHITECTURE

**الحالية:** لا يوجد.

**المقترحة** (بالتفصيل في تقرير Phase 0، القسم 2): app shell رفيع + Swift Packages محلية:
`TLFoundation → TLDomain → TLData / TLContextEngine / TLActionEngine / TLVision / TLAI`، و`TLDesignSystem`، و`TLLocalization`، و`TLFeatures`، و`TLPlatform`، مع ShareExtension وWidgetsExtension، وSwiftData داخل App Group.

---

## FEATURE MATRIX

### الحالة في المستودع

| الفئة | Implemented | Partially implemented | Missing |
|---|---|---|---|
| CORE (Command Center، Workspaces، Sessions، Notes، Calculator، Browser، PDF viewer، Image viewer، Clipboard، Smart actions، Share Extension) | — | — | الكل |
| SYSTEM INTEGRATION (App Intents، Shortcuts، Widgets، Live Activities، Dynamic Island، PiP) | — | — | الكل |
| INTELLIGENCE (Context/Action Engine، OCR، Vision، detectors، QR، AI) | — | — | الكل |
| SCREEN INTELLIGENCE | — | — | الكل |
| ADVANCED (Session types، resume، semantic search، AI actions) | — | — | الكل |

### فحص التكاملات المطلوبة (البند 5)

| التكامل | موجود في المستودع؟ |
|---|---|
| Share Extension | لا |
| Widget | لا |
| App Intents | لا |
| ActivityKit | لا |
| PiP (AVKit) | لا |
| ScreenCaptureKit | لا (وهو على أي حال غير متاح على iOS؛ macOS فقط) |
| Vision | لا |
| PDFKit | لا |
| WebKit | لا |

### الجدوى على iOS (البند 8)

| Fully supported | Partially supported | Unsupported |
|---|---|---|
| Command Center، Workspaces، Sessions، Notes، Calculator، Browser (WKWebView)، PDF viewer (PDFKit)، Image viewer، Smart actions، Share Extension، App Intents، Shortcuts، Widgets، OCR (Vision)، URL/phone/date/address detection (`NSDataDetector`)، QR/barcode، Context/Action Engine، Session templates، Smart resume، Core Spotlight text search | Clipboard intelligence (prompt عند القراءة، لا مراقبة خلفية)، Live Activities (مهام محددة زمنياً فقط)، Dynamic Island (أجهزة معينة، عبر Live Activities)، PiP (للفيديو أساساً، لغيره خطر رفض)، Currency (الكشف ممكن، التحويل يحتاج مزوّد أسعار خارجي)، AI (FoundationModels على أجهزة Apple Intelligence فقط)، User-initiated screen capture (Screenshot + Share Extension، أو ReplayKit Broadcast)، Semantic search (دعم العربية في `NLEmbedding` محدود)، OCR بالعربية (يُتحقق منه وقت التشغيل) | ScreenCaptureKit على iOS، نوافذ عائمة لتطبيقات أخرى، overlays على مستوى النظام، التحكم بتطبيق آخر، مراقبة الشاشة أو تسجيلها في الخلفية، سجل حافظة تلقائي في الخلفية |

---

## DEPENDENCIES

- **حالياً:** لا شيء.
- **المقترح للـ runtime:** صفر dependencies خارجية؛ Apple frameworks فقط (SwiftData، Vision، VisionKit، NaturalLanguage، PDFKit، WebKit، AppIntents، WidgetKit، ActivityKit، AVKit، Translation، FoundationModels اختياري).
- **أدوات تطوير مقترحة (ليست داخل التطبيق):** XcodeGen لتوليد المشروع، وGitHub Actions macOS للبناء والاختبار.

---

## APIs قد تسبب مشاكل مع أحدث iOS SDK (البند 6)

لا يوجد كود، فلا توجد APIs مستخدمة حالياً. ما سنتجنبه من البداية:
- `NSExpression` لحساب مدخلات المستخدم (يسبب crash على صيغ غير صالحة).
- `ObservableObject` في الكود الجديد (نستخدم `@Observable`).
- `UIApplication.shared.windows` و`keyWindow` (deprecated، لا تعمل مع multi-scene).
- `UIWebView` (مرفوض في App Store).
- قراءة `UIPasteboard.general.string` تلقائياً (تُظهر prompt للمستخدم).
- غياب `PrivacyInfo.xcprivacy` (يمنع الرفع إلى App Store).
- APIs الخاصة بـ iOS 26+ (FoundationModels، WebKit for SwiftUI، Visual Intelligence) تبقى خلف `#available`، ولا نعتمد عليها قبل أن يبنيها CI على الـ SDK الفعلي.

---

## RISKS

| # | المخاطرة | التخفيف |
|---|---|---|
| R1 | لا يوجد Xcode في هذه البيئة (Linux)، فلا يمكن البناء أو الاختبار هنا | GitHub Actions على macOS runner، أو Mac عبر Remote Control |
| R2 | تحرير `.xcodeproj` يدوياً من Linux هش | XcodeGen `project.yml` |
| R3 | PiP لمحتوى غير الفيديو قد يُرفض في App Review | مرحلة تجريبية متأخرة خلف feature flag |
| R4 | التسويق كـ "floating apps" قد يُرفض بسبب ادعاءات مضللة | الالتزام بوصف "Intelligent contextual multitasking" |
| R5 | حدود ذاكرة الـ extensions | معالجة ثقيلة مؤجلة للتطبيق عبر App Group |
| R6 | دقة OCR والكشف للعربية والأرقام العربية-الهندية | normalization وعيّنات اختبار حقيقية |
| R7 | توفر Apple Intelligence محدود | AI اختياري بالكامل |
| R8 | اسم المستودع `multi_pip` لا يطابق تعريف المنتج | لا يؤثر تقنياً؛ إعادة التسمية اختيارية |

---

## RECOMMENDED ROADMAP

| Phase | المحتوى |
|---|---|
| 2. Foundation | XcodeGen، App target، هيكل الـ Packages، App Group، String Catalog (ar/en)، Design System أولي، Privacy manifest، CI على macOS |
| 3. Domain + Data | النماذج وSwiftData المشترك |
| 4. Context Engine | detectors مع عيّنات عربية وإنجليزية |
| 5. Action Engine + Lens UI | الأفعال الأساسية وشاشة Lens |
| 6. Core features | Command Center، Workspaces، Sessions، Notes، Calculator |
| 7. Share Extension + Clipboard | |
| 8. Viewers + Vision | Browser، PDF، Image، OCR، QR، Translation |
| 9. System integration | App Intents، Shortcuts، Widgets، Spotlight |
| 10. Live Activities | |
| 11. Advanced Sessions + search | |
| 12. AI (اختياري) | |
| 13. Screen intelligence | Screenshot عبر Share Extension أولاً |
| 14. PiP (تجريبي) | |
| 15. Hardening | Accessibility، الأداء، مراجعة الخصوصية، بيانات App Store |

(هذا نفس تسلسل Phase 0، مع إزاحة الترقيم لأن هذه المرحلة أصبحت Phase 1.)

### قرارات مطلوبة قبل Phase 2
1. التحقق من البناء: GitHub Actions macOS (موصى به) أو Mac عبر Remote Control.
2. توليد المشروع: XcodeGen (موصى به).
3. الحد الأدنى للنظام: iOS 17.0 (موصى به).
4. Bundle ID وApp Group: placeholder (`com.example.tasklens`) حتى ترسل القيم الحقيقية.

---

## BUILD STATUS

**N/A.** لا يوجد مشروع لبنائه. إضافة لذلك، لا يتوفر `swift` ولا `xcodebuild` في هذه البيئة.

## TEST STATUS

**N/A.** لا توجد اختبارات، ولا توجد بيئة iOS لتشغيلها هنا.
