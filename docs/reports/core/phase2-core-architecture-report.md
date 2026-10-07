# TaskLens — Phase 2: Core Architecture Report

التاريخ: 2026-10-02
الفرع: `claude/project-thread-0s4dmt` (commit `2cff33e`)
CI: [Run #1 — نجح](https://github.com/rayan23923-cell/multi_pip/actions/runs/36964850746)

---

## 1. Architecture changes

بُني الأساس من الصفر، فالمستودع كان فارغاً. هذه القرارات التي اتخذتها بشكل افتراضي لأنك لم تحددها، ويمكن تغييرها:

| القرار | الاختيار |
|---|---|
| الجهاز المرجعي | **iPhone 11** (simulator)، وكل الاختبارات تعمل عليه في CI |
| Deployment target | iOS 17.0 |
| Swift | Swift 6 language mode (strict concurrency) |
| Toolchain المستخدم فعلياً | Xcode 26.6، Swift 6.3.3، iOS 26.5 simulator runtime، macOS 26 runner |
| توليد المشروع | XcodeGen (`project.yml`). ملف `.xcodeproj` يُولَّد ولا يُحفظ في git |
| Dependencies خارجية | **لا شيء**. Apple frameworks فقط |
| Bundle ID / App Group | Placeholders: `com.example.tasklens` و`group.com.example.tasklens` |

### الطبقات

```
TaskLensKit (بدون UI؛ يبني لـ iOS و macOS)
  TLFoundation    JSONValue، Identifier<T>، DateProviding، TaskLensError، TLLogger
  TLDomain        Models + Repository protocol + Engine contracts
  TLData          InMemoryRepository، JSONFileRepository، StoreLocation، Repositories
  TLCoreServices  Workspace / Session / Capture / Note / Clipboard services

TaskLensUI (SwiftUI)
  TLLocalization  String Catalog (en + ar)، L10nKey، رسائل الأخطاء
  TLDesignSystem  Tokens، cards، badges، empty states، rows، quick capture bar
  TLNavigation    AppTab، AppRoute، AppRouter
  Features        CommandCenter، Workspaces، Sessions، Settings

App
  AppContainer    Composition root (المكان الوحيد الذي يختار implementations)
  RootView        Tabs + NavigationStack لكل tab + ربط routes بالشاشات
```

### ما طُلب وكيف نُفِّذ

| المطلوب | التنفيذ |
|---|---|
| 1. Domain layer | 9 models: `Workspace`، `Session`، `ContextItem`، `DetectedEntity`، `Action`، `ActionResult`، `Document`، `Note`، `ClipboardItem` |
| 2. Data layer | `JSONFileRepository` (ملف JSON مُرقَّم بإصدار schema لكل entity، كتابة atomic، file protection) + `InMemoryRepository` |
| 3. Core services | 5 services مع validation وقواعد عمل (جلسة نشطة واحدة لكل workspace، cascade delete، dedupe، سجل حافظة محدود) |
| 4. Feature modules | 4 modules مستقلة لا تستورد بعضها |
| 5. Dependency boundaries | الـ services تعتمد على protocols فقط، والـ features لا تعرف `TLData`، والتطبيق وحده يركّب كل شيء |
| 6. Persistence abstraction | `Repository<Model>` protocol واحد؛ يمكن استبداله بـ SwiftData أو SQLite لاحقاً بدون لمس الـ services |
| 7. Navigation | `AppRouter` مع path لكل tab، و`AppRoute` قيم Hashable، جاهز لـ deep links و App Intents |
| 8. Localization | String Catalog بـ 74 مفتاحاً بالعربية والإنجليزية، مولَّد من `scripts/strings.py`، و`L10nKey` enum. لا توجد نصوص ثابتة في الواجهة |
| 9. Error handling | `TaskLensError` واحد بدون نصوص للمستخدم؛ الواجهة تحوّله لرسالة مترجمة |
| 10. Logging | `TLLogger` فوق OSLog. القاعدة: لا يُسجَّل محتوى المستخدم أبداً (معرّفات وأعداد فقط) |

### نقاط قابلية التوسع
- الأنواع التي ستكبر (`SessionKind`، `ContextSource`، `EntityType`، `ActionType`) مبنية كـ string-backed structs، فالقيم الجديدة من إصدار أحدث لا تكسر قراءة البيانات (يوجد اختبار لذلك).
- كل model يحمل `metadata: [String: JSONValue]` لإضافة حقول بدون migration.
- `Identifier<Workspace>` و`Identifier<Session>` نوعان مختلفان، فلا يمكن خلطهما compile-time.
- واجهات `EntityDetecting` و`ActionSuggesting` و`ActionPerforming` جاهزة لـ Context Engine و Action Engine في المراحل القادمة. حالياً `NoEntityDetector` لا يكتشف شيئاً.

### ما يمكن للمستخدم فعله في التطبيق الآن
- إنشاء workspaces (اسم + لون)، أرشفتها، حذفها.
- بدء جلسة بنوع (عامة، بحث، تسوق، دراسة، تطوير)، إيقافها مؤقتاً، استئنافها، إنهاؤها.
- التقاط نص سريع من Command Center (يذهب لآخر جلسة نشطة أو للوارد) أو من داخل الجلسة.
- الإعدادات: بيان الخصوصية، رابط لإعدادات اللغة، مكان التخزين، الإصدار.

---

## 2. Files created

79 ملفاً، حوالي 4,700 سطر Swift.

| المسار | المحتوى |
|---|---|
| `Packages/TaskLensKit/Sources/TLFoundation/` (5) | JSONValue، Identifier، DateProviding، TaskLensError، Logging |
| `Packages/TaskLensKit/Sources/TLDomain/` (13) | Models، Entity، Repository، EngineContracts |
| `Packages/TaskLensKit/Sources/TLData/` (4) | InMemoryRepository، JSONFileRepository، StoreLocation، Repositories |
| `Packages/TaskLensKit/Sources/TLCoreServices/` (6) | الخدمات الخمس + Validation |
| `Packages/TaskLensKit/Tests/` (14) | اختبارات الطبقات الأربع |
| `Packages/TaskLensUI/Sources/` (14) | Localization، DesignSystem، Navigation، 4 features |
| `Packages/TaskLensUI/Tests/` (3) | Localization، Router، Feature view models |
| `App/TaskLens/` (8) | App، AppContainer، RootView، Assets، PrivacyInfo.xcprivacy، InfoPlist.xcstrings |
| `App/TaskLensTests/` (1) | اختبارات التركيب |
| `project.yml`، `scripts/ci.sh`، `scripts/strings.py`، `.github/workflows/ci.yml` | البناء و CI والنصوص |
| `README.md`، `docs/ARCHITECTURE.md`، `.gitignore` | التوثيق |

لم يُعدَّل أي ملف قائم (لم يكن هناك أي ملف).

---

## 3. Tests

**83 اختباراً، كلها ناجحة على iPhone 11 simulator (iOS 26.5).** اختبارات TaskLensKit (68) تعمل أيضاً على macOS host.

| المجموعة | العدد | ما تغطيه |
|---|---|---|
| TLFoundation | 12 | JSON round-trip، الـ identifiers، مستويات الـ logging، مفاتيح الأخطاء |
| TLDomain | 20 | Codable لكل model، آلة حالات الجلسة، تقييد Confidence، ترتيب Actions، أنواع مجهولة من إصدار أحدث، عدم تسريب المحتوى للـ logs |
| TLData | 9 | نفس العقد على backend-ين (memory و JSON)، الاستمرارية بين instances، ملف تالف، fallback للتخزين |
| TLCoreServices | 27 | Validation، cascade delete، جلسة نشطة واحدة، dedupe، فشل الـ detector لا يضيّع المحتوى، حدود سجل الحافظة |
| TaskLensUI | 12 | كل مفتاح مترجم بالعربية والإنجليزية، كل خطأ له رسالة، Router، view models |
| App | 3 | تركيب الـ services من البداية للنهاية، فتح التخزين الدائم |

---

## 4. Build status

| الخطوة | النتيجة |
|---|---|
| `swift test` على macOS host | ✅ 68/68 |
| TaskLensKit على iPhone 11 simulator | ✅ TEST SUCCEEDED |
| TaskLensUI على iPhone 11 simulator | ✅ TEST SUCCEEDED |
| `xcodegen generate` | ✅ |
| بناء التطبيق + اختباراته على iPhone 11 | ✅ TEST SUCCEEDED |

نجح أول تشغيل لـ CI بدون أي أخطاء build أو test، لذلك لم تكن هناك أخطاء لإصلاحها.

ملاحظات:
- البناء في CI غير موقَّع (`CODE_SIGNING_ALLOWED=NO`)، لذلك App Group غير مفعَّل هناك ويستخدم التطبيق Application Support (هذا متوقع ومختبَر).
- لم يُبنَ على جهاز iPhone 11 حقيقي؛ هذا يحتاج Apple Developer account وتوقيعاً.
- هذه البيئة Linux بدون Xcode، فكل البناء والاختبارات تتم على GitHub Actions (macOS 26).

---

## 5. Privacy / Security / App Store review (Step G)

- لا شبكة، لا analytics، لا tracking، لا طرف ثالث.
- `PrivacyInfo.xcprivacy` موجود: tracking = false، لا بيانات مجمَّعة، لا Required Reason APIs مستخدمة حالياً.
- الملفات تُكتب بـ `completeFileProtectionUntilFirstUserAuthentication`.
- الـ logs لا تحتوي محتوى المستخدم (مُختبر).
- لا قراءة للحافظة إطلاقاً في هذه المرحلة؛ `PasteboardReading` مجرد protocol، وسيعتمد لاحقاً على `PasteButton` بدون prompt.
- `ITSAppUsesNonExemptEncryption = false`.

---

## 6. Risks

| # | المخاطرة | التخفيف المقترح |
|---|---|---|
| R1 | JSON store يعيد كتابة الملف كاملاً عند كل تغيير؛ مناسب لمئات/آلاف العناصر وليس لعشرات الآلاف | الانتقال إلى SwiftData أو SQLite خلف نفس `Repository` عند الحاجة (قبل Semantic search) |
| R2 | التطبيق والـ Share Extension سيكتبان نفس الملفات لاحقاً | الـ extension يكتب في "inbox" منفصل والتطبيق يدمجه، أو file coordination |
| R3 | iOS 26 هو آخر إصدار مؤكَّد يدعم iPhone 11. إن أسقط iOS 27 دعمه فلن يحصل على ميزاته | التطبيق يستهدف iOS 17+، فيبقى يعمل على iPhone 11 |
| R4 | iPhone 11 لا يدعم Apple Intelligence (FoundationModels) ولا Dynamic Island | AI اختياري بالكامل؛ Live Activities تعمل على Lock Screen بدون Dynamic Island |
| R5 | الـ identifiers placeholders | تحتاج قيمك الحقيقية قبل البناء على جهاز أو الرفع |
| R6 | دقائق macOS في GitHub Actions لها تكلفة في المستودعات الخاصة (كل تشغيل ≈ 9 دقائق) | يمكن تقليل التشغيل لـ pull requests فقط |
| R7 | الشاشات تعيد تحميل البيانات عند الظهور فقط، فلا تتحدث تلقائياً عند تغيّر البيانات من tab آخر | إضافة change notifications في مرحلة لاحقة |
| R8 | لا توجد UI tests (XCUITest) أو اختبارات RTL بصرية بعد | تُضاف مع الشاشات الحقيقية في المراحل القادمة |

---

## 7. Completed / Partial / Blocked / Assumptions

- **Completed:** كل البنود العشرة في Phase 2، والـ models التسعة، والاختبارات، والبناء على iPhone 11.
- **Partially completed:** `Document` و`ClipboardItem` لهما models و repositories، و`ClipboardService` كامل، لكن لا توجد شاشات لهما بعد (حسب نطاق المرحلة). `Note` له service واختبارات بدون شاشة.
- **Blocked:** لا شيء. البناء على جهاز حقيقي يحتاج حسابك.
- **Not implemented (حسب طلبك):** AI، ScreenCaptureKit، PiP.
- **Assumptions:** iOS 17 minimum، XcodeGen، GitHub Actions، placeholders للـ identifiers.
- **لا يوجد Pull Request:** المستودع كان فارغاً بدون default branch، فأصبح هذا الفرع هو الفرع الوحيد ولا يوجد base لفتح PR عليه.

---

## 8. Next phase (مقترح)

**Phase 3 — Context Engine:** detectors للروابط، الهواتف (بما فيها الصيغ العراقية `07xx`)، البريد، التواريخ، العناوين، الأرقام والعملات (مع تطبيع الأرقام العربية-الهندية ٠-٩)، واللغة، باستخدام `NSDataDetector` و`NaturalLanguage`، خلف `EntityDetecting`. مع مجموعة اختبارات كبيرة بعيّنات عربية وإنجليزية.
