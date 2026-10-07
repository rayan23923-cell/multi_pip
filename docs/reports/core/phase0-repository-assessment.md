# TaskLens — Phase 0: Repository Assessment & Architecture Plan

التاريخ: 2026-10-02
المستودع: `rayan23923-cell/multi_pip`
الحالة: تقرير فحص وتخطيط فقط. لم يُكتب أو يُعدَّل أي كود.

---

## 1. نتيجة فحص المستودع (Step A)

| البند المطلوب | النتيجة | كيف تم التحقق |
|---|---|---|
| App target | **لا يوجد** | المستودع فارغ |
| Deployment target | لا يوجد | — |
| Swift version | لا يوجد | — |
| Architecture | لا يوجد | — |
| Dependencies | لا يوجد | — |
| Build configuration | لا يوجد | — |
| Extensions | لا يوجد | — |
| Tests | لا يوجد | — |
| Existing functionality | لا يوجد | — |

الأدلة:
- `git log` محلياً: `your current branch ... does not have any commits yet`.
- GitHub API: `list_branches` أعاد قائمة فارغة، و`get_file_contents` أعاد `409 Git Repository is empty`.
- مجلد الملفات المشترك للمشروع فارغ (لا ملفات مرفوعة).

**الخلاصة:** المشروع Greenfield بالكامل. لا توجد أجزاء مستقرة يجب الحفاظ عليها، وبالتالي القرارات المعمارية أدناه هي اقتراح بداية وليست وصفاً لشيء قائم.

ملاحظة: اسم المستودع `multi_pip` يوحي بفكرة "PiP متعدد"، وهذا يتعارض مع تعريف المنتج الجديد ("ليس تطبيق PiP"). لا مشكلة تقنية، لكن يُفضّل لاحقاً إعادة تسمية المستودع أو على الأقل تسمية الـ target باسم `TaskLens`.

### قيود بيئة العمل الحالية
- هذه البيئة **Linux** بدون Xcode وبدون Swift toolchain (`swift` و`xcodebuild` غير موجودين).
- **لا يمكن هنا** بناء تطبيق iOS، ولا تشغيل Simulator، ولا تشغيل XCTest/Swift Testing على iOS، ولا توقيع التطبيق.
- لذلك Steps D/E (Build + Tests) تحتاج أحد البدائل التالية (انظر القسم 7):
  1. **GitHub Actions على macOS runner** (موصى به): كل push يبني ويشغّل الاختبارات على Xcode حقيقي، وأقرأ النتائج من هنا.
  2. Remote Control على جهاز Mac لديك.
  3. أن تبني أنت محلياً وترسل لي الأخطاء.

---

## 2. Architecture Map (مقترحة)

بما أنه لا توجد معمارية قائمة، أقترح **Modular SPM architecture**: تطبيق Xcode رفيع (thin app shell) + Swift Packages محلية. السبب: كل feature قابلة للاختبار مستقلاً، والـ extensions (Share / Widget) تستورد فقط الـ modules التي تحتاجها، مما يحافظ على حدود الذاكرة في الـ extensions.

```
TaskLens/
├── App/                        ← iOS app target (thin): DI, routing, scenes
├── Extensions/
│   ├── ShareExtension/         ← استقبال URL/Text/Image/PDF من أي تطبيق
│   ├── WidgetsExtension/       ← Widgets + Live Activities + Control widgets
│   └── (later) BroadcastUpload ← اختياري، ReplayKit screen capture
├── Packages/
│   ├── TLFoundation/           ← Core: logging, errors, IDs, clock, utilities
│   ├── TLDomain/               ← Domain models + protocols (لا يعتمد على UIKit)
│   │     Workspace, Session, Item(Content), ContextKind, Action, Note …
│   ├── TLData/                 ← Persistence (SwiftData) في App Group container
│   ├── TLContextEngine/        ← Content → Context (classification, detectors)
│   ├── TLActionEngine/         ← Context → [Action] (registry + ranking + execution)
│   ├── TLVision/               ← OCR, barcode/QR, image analysis (Vision/VisionKit)
│   ├── TLAI/                   ← AIProvider protocol + FoundationModels provider + NoAI
│   ├── TLDesignSystem/         ← tokens, cards, components, RTL-safe layout
│   ├── TLLocalization/         ← String Catalog (.xcstrings) + helpers
│   ├── TLFeatures/             ← وحدة لكل feature (SwiftUI + ViewModel)
│   │     CommandCenter, Workspaces, Sessions, Notes, Calculator,
│   │     Browser, Documents, ImageViewer, Clipboard, Lens
│   └── TLPlatform/             ← AppIntents, Widgets shared, LiveActivity, PiP
└── Tests/                      ← Swift Testing لكل package + UI tests للتطبيق
```

### تدفق البيانات الأساسي (ACTION LENS)

```
Input (Share / Paste / Capture / Import / Intent)
   │
   ▼
ContentItem  (text | url | image | pdf | file)       ← TLDomain
   │
   ▼
ContextEngine.analyze(item) → [DetectedContext]      ← TLContextEngine (+ TLVision لصور/PDF)
   │   currency, phone, url, date, address, email, qr, language, …
   ▼
ActionEngine.actions(for: contexts) → [ActionSuggestion]   ← TLActionEngine
   │   ranked, each Action = id + availability + perform()
   ▼
Lens UI (sheet / card)  → user picks → Action executes
   │
   ▼
Saved into Workspace → grouped into Session             ← TLData
```

قواعد تصميم أساسية:
- `TLDomain` و`TLContextEngine` و`TLActionEngine` لا تستورد SwiftUI/UIKit قدر الإمكان → اختبارات سريعة ونقية.
- كل Action تُعرَّف كـ protocol مع `isAvailable(context)` و`perform()`؛ الـ AI actions تُسجَّل فقط إذا كان AI متاحاً. **لا وظيفة أساسية تعتمد على AI.**
- الـ extensions والتطبيق يتشاركان البيانات عبر **App Group** (SwiftData store في الـ shared container).
- Swift 6 language mode مع strict concurrency من البداية (تجنّب ديون ترحيل لاحقاً).
- Observation framework (`@Observable`) بدلاً من `ObservableObject`.

### الإعدادات المقترحة
| البند | الاقتراح | السبب |
|---|---|---|
| Minimum iOS | **iOS 17.0** | SwiftData، `@Observable`، interactive widgets، TipKit. ميزات iOS 18/26 تُفعَّل بـ `#available` |
| Xcode | أحدث Xcode مستقر (Xcode 26.x أو أحدث) | يجب التحقق على الـ Mac/CI من رقم الـ SDK الفعلي |
| Swift | Swift 6 language mode | concurrency safety |
| UI | SwiftUI أولاً، UIKit عند الحاجة فقط (PiP، PDFKit، Share Extension host) |
| Persistence | SwiftData داخل App Group | Offline-first |
| Localization | String Catalog (`Localizable.xcstrings`) — Arabic + English من اليوم الأول | لا strings ثابتة في الكود |
| Tests | Swift Testing للـ packages، XCTest/XCUITest للـ UI |
| Project generation | **XcodeGen** (`project.yml`) — أداة تطوير فقط، ليست runtime dependency | توليد `.xcodeproj` يدوياً من Linux هش جداً؛ هذا يحتاج موافقتك (قسم 8) |

---

## 3. Dependency Map

### Runtime: صفر dependencies خارجية (المقترح)
كل شيء ممكن بـ Apple frameworks:

| Module | Apple frameworks |
|---|---|
| TLData | SwiftData, Foundation |
| TLContextEngine | Foundation (`NSDataDetector`, `Regex`, `NumberFormatter`, `Locale.Currency`), NaturalLanguage |
| TLVision | Vision (`VNRecognizeTextRequest`, `VNDetectBarcodesRequest`؛ وواجهات Vision الجديدة في iOS 18+)، VisionKit (`ImageAnalyzer`, `DataScannerViewController`) |
| TLActionEngine | UIKit (`UIApplication.open` لـ `tel:`/`sms:`/`mailto:`)، MessageUI، ContactsUI، EventKitUI، MapKit |
| Browser | WebKit (`WKWebView`)، SafariServices، LinkPresentation |
| Documents | PDFKit، QuickLook، UniformTypeIdentifiers |
| Translation | Translation framework (iOS 17.4+ UI، iOS 18+ `TranslationSession`) |
| TLAI | FoundationModels (iOS 26+، أجهزة Apple Intelligence فقط) — اختياري |
| TLPlatform | AppIntents، WidgetKit، ActivityKit، AVKit (PiP)، CoreSpotlight |
| Screen capture (later) | ReplayKit |

### Graph الاعتماديات الداخلية
```
TLFoundation ◄── TLDomain ◄── TLData
                     ▲   ▲
                     │   └── TLContextEngine ◄── TLVision
                     │              ▲
                     └──────── TLActionEngine ◄── TLAI (optional)
TLDesignSystem, TLLocalization ◄── TLFeatures ◄── App
TLPlatform ◄── App, WidgetsExtension
ShareExtension → TLDomain, TLData, TLContextEngine, TLDesignSystem (فقط)
```

### Dependencies خارجية قد تُطلب لاحقاً (غير ضرورية الآن)
- **أسعار الصرف** لتحويل العملات: لا يوجد API من Apple. يتطلب مزوّد خارجي عبر الشبكة (ليس SDK)، مع cache محلي وعرض تاريخ آخر تحديث. قرار لاحق.
- **Cloud AI provider** (اختياري، opt-in) للأجهزة غير الداعمة لـ Apple Intelligence. قرار لاحق.

---

## 4. Current Features

لا توجد أي ميزة منفّذة. المستودع فارغ.

---

## 5. Missing Features + iOS Public-API Feasibility

التصنيف: ✅ مدعوم | 🟡 مدعوم جزئياً / بشروط | ❌ غير مدعوم (مع البديل)

### CORE
| الميزة | الحالة | الـ API / الملاحظة |
|---|---|---|
| Command Center | ✅ | SwiftUI داخل التطبيق |
| Workspaces / Sessions | ✅ | SwiftData + App Group |
| Notes | ✅ | SwiftUI `TextEditor` / rich text (iOS 26 يضيف `AttributedString` editing في `TextEditor` — يُتحقق منه) |
| Calculator | ✅ | parser خاص بنا. **لا** نستخدم `NSExpression` لمدخلات المستخدم (يسبب crash على صيغ غير صالحة) |
| Browser | ✅ | `WKWebView` (أو WebKit for SwiftUI في iOS 26+). لا يمكن الوصول لكوكيز Safari أو جلسات المستخدم فيه |
| PDF/Document viewer | ✅ | PDFKit + QuickLook |
| Image viewer | ✅ | SwiftUI + VisionKit Live Text (`ImageAnalysisInteraction`) |
| Clipboard intelligence | 🟡 | قراءة `UIPasteboard` تُظهر banner/طلب إذن "Allow Paste" (iOS 16+). **لا يمكن مراقبة الحافظة في الخلفية ولا بناء clipboard history تلقائي.** البديل: `PasteButton`/`UIPasteControl` (بدون prompt)، و`detectPatterns(for:)` لمعرفة نوع المحتوى قبل القراءة، وقراءة عند فتح التطبيق بموافقة المستخدم |
| Smart actions | ✅ | Action Engine داخلي |
| Share Extension | ✅ | حد ذاكرة صارم في الـ extensions → معالجة خفيفة في الـ extension، والمعالجة الثقيلة (OCR لملف PDF كبير) تُؤجَّل للتطبيق |

### SYSTEM INTEGRATION
| الميزة | الحالة | الملاحظة |
|---|---|---|
| App Intents | ✅ | iOS 16+. AppEntity للـ Workspace/Session/Note |
| Shortcuts | ✅ | App Shortcuts عبر AppIntents (تظهر تلقائياً في Shortcuts و Spotlight) |
| Widgets | ✅ | WidgetKit؛ interactive (buttons/toggles) من iOS 17؛ Control Center controls من iOS 18 |
| Live Activities | 🟡 | ActivityKit. مخصصة لمهمة **محددة زمنياً وجارية** (مثل Session نشطة أو timer). مدة محدودة من النظام، ولا تقبل تفاعل غير App Intents. استخدامها كـ "لوحة دائمة" يخالف الغرض وقد يُرفض |
| Dynamic Island | 🟡 | عبر Live Activities فقط، وعلى الأجهزة التي تملك Dynamic Island فقط |
| PiP | 🟡 **عالي المخاطرة** | `AVPictureInPictureController` مع `AVSampleBufferDisplayLayer` (iOS 15+) يسمح برسم محتوى مخصص. لكن: PiP مصمم للفيديو/مكالمات الفيديو، ويتطلب Background Mode للصوت/PiP، واستخدامه لعرض UI غير فيديو (ملاحظات، حاسبة) **معرّض للرفض في App Review**. لا يمكن التفاعل مع المحتوى داخل نافذة PiP (فقط أزرار التحكم القياسية). يُعامَل كمكوّن تجريبي متأخر وليس أساس المنتج |
| Floating windows لتطبيقات أخرى | ❌ | غير ممكن. البديل: Share Extension + Widgets + Live Activity + PiP محدود |

### INTELLIGENCE
| الميزة | الحالة | الملاحظة |
|---|---|---|
| Context Engine | ✅ | داخلي |
| Action Engine | ✅ | داخلي |
| OCR | ✅ | Vision text recognition. دعم العربية يجب التحقق منه وقت التشغيل عبر `supportedRecognitionLanguages()` على الـ SDK الفعلي، مع fallback واضح إذا لم تتوفر |
| Vision (classification) | ✅ | Vision image classification / VisionKit |
| URL classification | ✅ | `NSDataDetector` + `URLComponents` + قواعد domain + LinkPresentation للـ metadata |
| Text classification | ✅ | NaturalLanguage (`NLLanguageRecognizer`, `NLTagger`)؛ تصنيف أدق اختياري عبر Core ML أو FoundationModels |
| Number/currency | 🟡 | الكشف ✅ (Regex + `Locale.Currency` + رموز مثل `$` و`د.ع` و`IQD`). **التحويل** يحتاج أسعار صرف من الشبكة (لا API من Apple) |
| Phone | ✅ | `NSDataDetector(.phoneNumber)` + `tel:` (النظام يعرض تأكيد قبل الاتصال). صيغ الأرقام العراقية (`077…`) تُختبر بحالات اختبار خاصة |
| Date | ✅ | `NSDataDetector(.date)` + EventKitUI لإضافة حدث (لا يحتاج full calendar access) |
| Address | ✅ | `NSDataDetector(.address)` + MapKit geocoding. دقة العناوين العربية/العراقية متوسطة — يُوثَّق |
| QR/barcode | ✅ | `VNDetectBarcodesRequest` للصور، `DataScannerViewController` للكاميرا الحية (أجهزة A12+) |
| AI integration | 🟡 | FoundationModels (iOS 26+) على أجهزة Apple Intelligence فقط، وبحسب اللغات المدعومة؛ يجب فحص `SystemLanguageModel.default.availability` وقت التشغيل. للأجهزة الأخرى: لا AI، أو مزوّد سحابي opt-in لاحقاً |

### SCREEN INTELLIGENCE
| الميزة | الحالة | الملاحظة |
|---|---|---|
| ScreenCaptureKit | ❌ **غير متاح على iOS** | ScreenCaptureKit إطار macOS فقط. لا يمكن استخدامه في تطبيق iPhone |
| User-initiated screen capture | 🟡 | البدائل العامة على iOS: (1) المستخدم يأخذ screenshot ثم يرسلها عبر Share Extension — **الأبسط والأكثر احتراماً للخصوصية، موصى به**؛ (2) `PhotosPicker` لاختيار لقطات الشاشة؛ (3) ReplayKit Broadcast Upload Extension: بث نظامي يبدأه المستخدم من picker، مع مؤشر تسجيل ظاهر، وحد ذاكرة صغير جداً للـ extension — معقّد وحساس في App Review؛ (4) تكامل App Intents مع Visual Intelligence على لقطات الشاشة (iOS 26+، أجهزة Apple Intelligence) — يُتحقق من الـ API على الـ SDK الفعلي قبل الالتزام |
| OCR/Context/Action على اللقطة | ✅ | بعد وصول الصورة للتطبيق، نفس pipeline الـ Lens |
| Hidden monitoring / background recording | ❌ | ممنوع تقنياً وسياسياً. لن يُنفَّذ |

### ADVANCED
| الميزة | الحالة | الملاحظة |
|---|---|---|
| Research/Shopping/Study/Developer Sessions | ✅ | Session templates + قواعد Action مخصصة لكل نوع |
| Smart Session resume | ✅ | حفظ الحالة + `NSUserActivity` / App Intents + Spotlight |
| Semantic search | 🟡 | Core Spotlight للبحث النصي ✅. البحث الدلالي: `NLEmbedding` (دعم العربية محدود ويجب اختباره) أو embeddings من FoundationModels/Core ML. نبدأ بالبحث النصي ثم نضيف الدلالي |
| AI Action Engine | 🟡 | فوق TLAI، اختياري، لا يُكسر شيئاً عند غيابه |
| التحكم بتطبيق آخر | ❌ | غير ممكن. البديل: URL schemes / Universal Links، وتمرير البيانات عبر Shortcuts و App Intents الخاصة بالتطبيقات الأخرى |

---

## 6. Risks

| # | المخاطرة | الأثر | التخفيف |
|---|---|---|---|
| R1 | لا Xcode في هذه البيئة | لا يمكن التحقق من البناء والاختبارات هنا | GitHub Actions macOS CI (أو Mac عبر Remote Control). ملاحظة: دقائق macOS في المستودعات الخاصة مكلفة نسبياً |
| R2 | ملف `.xcodeproj` لا يمكن تحريره بأمان من Linux | تعارضات وفساد ملف المشروع | XcodeGen `project.yml` + الكود الفعلي في Swift Packages |
| R3 | PiP لمحتوى غير فيديو | رفض App Store (Guidelines 2.5.x / الاستخدام غير المقصود لـ background modes) | يُؤجَّل لمرحلة متأخرة، feature flag، ويُستخدم فقط لمحتوى وسائطي/مؤقت مبرَّر |
| R4 | تسويق "Floating apps" أو "screen intelligence" | رفض بسبب ادعاءات مضللة (Guideline 2.3) | نص المتجر يلتزم بـ "Intelligent contextual multitasking" |
| R5 | Clipboard prompts | تجربة مزعجة، انطباع سلبي عن الخصوصية | `PasteButton`، لا قراءة تلقائية صامتة |
| R6 | حدود ذاكرة الـ Share/Broadcast extensions | crash عند PDFs/صور كبيرة | معالجة مؤجلة في التطبيق عبر App Group |
| R7 | OCR والكشف للعربية | دقة أقل للخطوط العربية/العناوين/الأرقام المختلطة (٠١٢ مقابل 012) | normalization للأرقام العربية-الهندية، اختبارات بعيّنات حقيقية، تحقق وقت التشغيل من اللغات |
| R8 | توفر Apple Intelligence | FoundationModels غير متاح على أغلب الأجهزة الأقدم/بعض المناطق واللغات | AI اختياري بالكامل، كل Action أساسي يعمل بدونه |
| R9 | أسعار الصرف | تحتاج شبكة ومزوّد خارجي، دقة ومسؤولية | cache + تاريخ آخر تحديث + ذكر المصدر؛ قرار المزوّد يعود لك |
| R10 | Privacy manifest | رفض الرفع بدون `PrivacyInfo.xcprivacy` لـ Required Reason APIs (مثل UserDefaults، file timestamps) | إضافته من Phase 1 للتطبيق وكل extension |
| R11 | SwiftData + App Group + extensions | تعارض كتابة متزامنة بين التطبيق والـ extension | الـ extension يكتب "inbox items" فقط، والتطبيق يعالجها |
| R12 | اختلاف الـ SDK الفعلي (اليوم أكتوبر 2026) عن معلوماتي | API تغيّرت أو أُضيفت | كل API جديد (iOS 26+) يُتحقق منه بالبناء على CI قبل الاعتماد عليه، ولا يُفترض وجود API غير مُثبت |
| R13 | RTL | تخطيطات مكسورة بالعربية | leading/trailing فقط، معاينات RTL، UI tests بالعربية |

---

## 7. Proposed Implementation Sequence

كل مرحلة تتبع Workflow A→I، ولا ننتقل قبل أن يكون البناء والاختبارات خضراء على CI.

| Phase | المحتوى | معيار الإنجاز |
|---|---|---|
| **0** (هذا التقرير) | فحص + خطة | ✓ |
| **1. Foundation** | XcodeGen project، App target، Packages فارغة بهيكلها، App Group، String Catalog (ar + en)، Design System أولي، `PrivacyInfo.xcprivacy`، GitHub Actions macOS build + test، SwiftLint اختياري | التطبيق يبني ويعمل على Simulator في CI، اختبار واحد على الأقل لكل package |
| **2. Domain + Data** | نماذج Workspace/Session/ContentItem/Note، SwiftData store مشترك، repositories | اختبارات CRUD |
| **3. Context Engine** | detectors: URL، phone (مع صيغ عراقية)، email، date، address، number/currency، language؛ normalization للأرقام العربية | test suite كبير بعيّنات عربية وإنجليزية |
| **4. Action Engine + Lens UI** | Action registry، ranking، الأفعال الأساسية (call، message، open، copy، share، save، add to calendar، add contact، map) + شاشة Lens | تدفق كامل: نص ← سياق ← أفعال |
| **5. Core features** | Command Center، Workspaces، Sessions، Notes، Calculator | UI tests أساسية، RTL |
| **6. Share Extension + Clipboard** | استقبال text/url/image/pdf، inbox، `PasteButton` | مشاركة من Safari/Photos تعمل |
| **7. Viewers + Vision** | Browser، PDF، Image viewer، OCR، QR/barcode، Live Text، Translation | OCR على صور اختبار |
| **8. System integration** | App Intents، App Shortcuts، Widgets (interactive)، Control widgets، Spotlight | تظهر في Shortcuts و Widgets |
| **9. Live Activities** | Session نشطة / timer في Lock Screen و Dynamic Island | |
| **10. Sessions المتقدمة** | Research/Shopping/Study/Developer templates، Smart resume، search | |
| **11. AI (اختياري)** | `AIProvider` + FoundationModels: summarize، extract، ask | كل شيء يعمل عند غياب AI |
| **12. Screen intelligence** | Screenshot → Share Extension pipeline أولاً؛ ثم تقييم ReplayKit / Visual Intelligence | |
| **13. PiP (تجريبي)** | فقط بعد مراجعة مخاطرة App Review، خلف feature flag | |
| **14. Hardening** | Accessibility audit، performance، privacy review، App Store metadata | |

---

## 8. قرارات مطلوبة منك قبل Phase 1

1. **التحقق من البناء:** أوصي بـ GitHub Actions على macOS runner. البديل: Remote Control على Mac لديك.
2. **توليد المشروع:** أوصي بـ XcodeGen (أداة تطوير فقط، لا تدخل في التطبيق).
3. **Minimum iOS:** أوصي بـ iOS 17.0.
4. **Bundle ID و App Group:** أقترح placeholders مثل `com.example.tasklens` و`group.com.example.tasklens` إلى أن تعطيني قيمك الحقيقية (يحتاج Apple Developer account للتوقيع على جهاز حقيقي فقط، وليس للـ Simulator/CI).

---

## 9. Phase 0 Report (Step I)

- **Completed:** فحص المستودع (فارغ)، فحص البيئة (Linux، لا Xcode)، معمارية مقترحة، dependency map، خريطة جدوى iOS لكل ميزة، المخاطر، تسلسل المراحل.
- **Partially completed:** لا شيء.
- **Blocked:** البناء والاختبارات (Steps D/E) غير ممكنة في هذه البيئة حتى يُعتمد CI أو Mac.
- **Assumptions:** iOS 17 minimum؛ Xcode/SDK الأحدث المستقر؛ ميزات iOS 26+ (FoundationModels، Visual Intelligence integration، WebKit for SwiftUI) تحتاج تحققاً على الـ SDK الفعلي قبل الاعتماد عليها.
- **Next phase:** Phase 1 — Foundation، بانتظار تعليماتك والقرارات في القسم 8.
