# TaskLens — المرحلة 17: مراجعة الامتثال لـ App Store

راجعتُ الكود كما يراجعه فريق App Review. كل ادعاء هنا مأخوذ من الكود في الفرع `claude/project-thread-0s4dmt`، والملف والسطر مذكوران حيث يهم.

**الخلاصة:**
- لا توجد private APIs.
- لا تسجيل ولا مراقبة في الخفاء.
- لا تتبع ولا تحليلات ولا SDK من طرف ثالث.
- **ما يمنع الإرسال حالياً:**
  1. لا توجد أيقونة تطبيق. `AppIcon.appiconset` فارغ.
  2. المعرّفات ما زالت مؤقتة: `com.example.tasklens` و`group.com.example.tasklens`.
  3. لم يُوقَّع أي بناء ولم يُختبر على جهاز حقيقي.
- **أعلى مخاطر المراجعة:**
  1. وضع الخلفية `audio` الذي تحتاجه نافذة PiP مع أن التطبيق لا يشغّل صوتاً (البند 2.5.4).
  2. المتصفح داخل التطبيق يفرض تصنيف عمر «Unrestricted Web Access».

---

## 1. بنية الخصوصية (Privacy architecture)

| الطبقة | ما يحدث فعلاً | أين في الكود |
|---|---|---|
| التخزين | ملفات JSON محلية في حاوية التطبيق أو App Group، مع `completeFileProtection` على iOS. لا قاعدة بيانات سحابية ولا مزامنة iCloud. | `TLData/JSONFileRepository.swift`، `StoreLocation` |
| الملفات المستوردة | تُنسخ إلى مجلد Files داخل الحاوية، وتُحذف مع مساحة العمل أو مع «حذف كل البيانات». | `DocumentService`، `DataControl` |
| تحليل المحتوى | محركا Context وAction يعملان بقواعد على الجهاز. OCR عبر Vision، والبحث بالمعنى عبر NaturalLanguage، وكلاهما على الجهاز. | `TLCoreServices/Engine`، `OnDeviceSemanticRanker` |
| الذكاء الاصطناعي | Apple Intelligence على الجهاز. أو خادم يختاره المستخدم، وهو معطّل افتراضياً، HTTPS فقط، والمفتاح في Keychain. يُعرض كشف بعدد الأحرف والمضيف قبل كل إرسال، ويُرسل النص فقط. | `AI/AIProviders.swift`، `AIEngine.swift` |
| الشبكة | اتصالان فقط: (1) المتصفح الذي يفتح ما يكتبه المستخدم، (2) خادم AI إذا فعّله المستخدم. لا طلبات أخرى. `NWPathMonitor` لا يرسل شيئاً. | `WebViewStore`، `AIServerProvider` |
| الحافظة | لا قراءة تلقائية أبداً. اللصق عبر `PasteButton` من النظام، لذلك لا يظهر شريط «TaskLens pasted from…». `changeCount` و`hasStrings` لا يقرآن المحتوى. | `ClipboardView`، `ClipboardModel.swift:46` |
| الشاشة | iOS 27+ فقط، وبعد ضغطة من المستخدم على منتقي النظام `SCContentSharingPicker`. يلتقط إطاراً واحداً ثم يتوقف، ويتوقف تلقائياً بعد 5 دقائق. لا تُحفظ الإطارات ولا تُرفع. مؤشر النظام والنشاط المباشر ظاهران طوال التشغيل. | `LensFeature/ScreenCaptureKitCapture.swift` |
| امتداد المشاركة | لا يكتب في المخزن مباشرة. يضع العناصر في صندوق صادر، والتطبيق يستلمها عند فتحه. لا شبكة. | `ShareOutbox` |
| الويدجت والنشاط المباشر | يقرآن لقطة صغيرة: العناوين والعدّادات فقط. | `WidgetSnapshot`، `SessionActivity` |
| التشخيص | MetricKit إلى سجل الجهاز فقط، ولا يُرسل. | `App/TaskLens/CrashDiagnostics.swift` |
| تحكم المستخدم | من الإعدادات: تصدير كل البيانات JSON، وحذف كل شيء (يشمل مفتاح AI وإعداداته)، وحذف سجل AI وإيقافه. | `DataControl`، `SettingsFeature` |
| النسخ الاحتياطي | البيانات تدخل في نسخة الجهاز الاحتياطية العادية (iCloud Backup أو الكمبيوتر). هذا مذكور في الإعدادات. | `settings.data.footer` |

## 2. مصفوفة جمع البيانات (Data collection matrix)

«الجمع» بتعريف Apple يعني أن تصل البيانات إلى المطوّر أو شركائه. TaskLens لا يملك خادماً.

| نوع البيانات | أين تبقى | تخرج من الجهاز؟ | يجمعها المطوّر؟ | تتبع؟ |
|---|---|---|---|---|
| النصوص والملاحظات والروابط | على الجهاز | لا | لا | لا |
| الصور ولقطات الشاشة | على الجهاز إن حفظها المستخدم، وإلا تُقرأ ثم تُترك | لا | لا | لا |
| إطار الشاشة (Screen Lens) | في الذاكرة فقط، ثم يُحذف | لا | لا | لا |
| ملفات PDF والمستندات | على الجهاز | لا | لا | لا |
| محتوى الحافظة | على الجهاز، وفقط ما يلصقه المستخدم بنفسه | لا | لا | لا |
| نص طلب AI | جهاز أو خادم يختاره المستخدم | فقط إذا فعّل المستخدم خادمه | لا (الخادم ليس للمطوّر) | لا |
| مفتاح API | Keychain | لا، إلا إلى خادم المستخدم نفسه | لا | لا |
| صفحات المتصفح | WebKit | نعم، إلى المواقع التي يفتحها المستخدم | لا | لا |
| بيانات الأعطال | سجل الجهاز | لا | لا | لا |
| المعرّفات والموقع وجهات الاتصال | لا تُستخدم | — | — | — |

## 3. شرح الصلاحيات (Permission explanation)

| الصلاحية | متى تُطلب | ماذا يرى المستخدم قبل طلب النظام |
|---|---|---|
| الكاميرا (`NSCameraUsageDescription`) | فقط عند ضغط «الكاميرا» في العدسة | **أُضيف في هذه المرحلة (`a9daca4`):** تنبيه «استخدام الكاميرا للعدسة؟» يشرح أن الصورة تُقرأ على الجهاز ولا تُرفع، ثم «متابعة» أو «ليس الآن». إذا كانت الصلاحية مرفوضة يظهر شرح وزر لفتح الإعدادات بدل شاشة سوداء. |
| تسجيل الشاشة (`NSScreenCaptureUsageDescription`، iOS 27+) | عند «بدء عدسة الشاشة» | نص خصوصية ظاهر في القسم قبل الزر، ثم منتقي النظام الذي يختار منه المستخدم ما يُشارك. |
| الأنشطة المباشرة | يقررها iOS، ولا يُعرض طلب داخل التطبيق | إذا كانت متوقفة يظهر شرح في الإعدادات (أُضيف في المرحلة 16). |
| الصور (PhotosPicker) | لا يُطلب إذن | المنتقي يعمل خارج التطبيق ويعطي الصورة المختارة فقط. |
| التقويم (EKEventEditViewController) | لا يُطلب إذن على iOS 17+ | محرر النظام يعمل خارج التطبيق، والمستخدم يضغط «إضافة» بنفسه. |
| الحافظة | لا يوجد طلب | يُستخدم `PasteButton` من النظام. |
| الموقع، جهات الاتصال، الميكروفون، الإشعارات، التتبع (ATT) | لا تُستخدم | — |

نصوص `Info.plist` مترجمة إلى العربية في `InfoPlist.xcstrings`.

## 4. إجابات App Store Connect للخصوصية (App Privacy)

- **Do you or your third-party partners collect data from this app?** → **No, we do not collect data from this app.**
  - **حكم شخصي يجب أن تقرّه:** خادم AI يضيفه المستخدم بنفسه (عنوانه ومفتاحه) ليس شريكاً للمطوّر، لذلك لا يُعدّ جمعاً.
  - إن أردت الخيار الأكثر تحفظاً، صرّح بـ: User Content › Other User Content، غير مرتبط بالهوية، وغير مستخدم للتتبع، والغرض App Functionality.
- **Tracking:** لا. `NSPrivacyTracking = false` ولا توجد نطاقات تتبع.
- **Privacy manifests:** موجودة في التطبيق والامتدادين. تصرّح بـ UserDefaults (CA92.1) وFile timestamp (C617.1) ولا شيء غير ذلك.
- **Privacy Policy URL:** مطلوب حتى مع «لا نجمع بيانات». **غير موجود بعد**، ويجب نشر صفحة.
- **Encryption:** `ITSAppUsesNonExemptEncryption = false`، لأن التطبيق يستخدم HTTPS من النظام فقط.

## 5. ملاحظات المراجعة (App Review notes)، نص جاهز بالإنجليزية

> TaskLens works fully offline and needs no account. All analysis (text, OCR, search) runs on the device. Nothing is sent to us; we run no servers, analytics or SDKs.
>
> **Picture in Picture:** started only when the user taps "Start Picture in Picture". It shows the user's own TaskLens cards (notes, results) as a floating window using AVPictureInPictureController with a sample-buffer layer. The `audio` background mode is required by iOS for any PiP window to stay visible in the background. The app plays no audio and uses `.playback` with `.mixWithOthers` so the user's audio is not interrupted. Steps: Command Center › Picture in Picture › Start Picture in Picture.
>
> **Screen Lens (iOS 27+ only):** the user taps Start, then picks content in the system SCContentSharingPicker. One frame is read on the device, then the stream stops (it also stops after 5 minutes). The system recording indicator and our Live Activity with a Stop button are visible the whole time. Frames are never saved or uploaded. On iOS 17–26 this section explains that a screenshot can be imported instead.
>
> **AI:** optional. It uses Apple Intelligence on device where available. An external server is off by default; the user can add their own HTTPS server and key. Before each request the app shows exactly how many characters will be sent and to which host. Suggestions are never executed automatically.
>
> **In-app browser:** opens only addresses the user types or links they saved. `NSAllowsArbitraryLoadsInWebContent` is set so plain http pages the user types can load in WKWebView. The rest of the app keeps ATS on.
>
> **Clipboard:** never read automatically; pasting uses the system PasteButton.
>
> No demo account is needed.

## 6. حدود الميزات (Feature limitations)

- **Screen Lens:** iOS 27+ فقط. `SCContentSharingPicker` ما زال مُعلَّماً beta على iOS. لم يُبنَ ولم يُختبر في CI لأن Xcode 26.6 بلا SDK الخاص بـ iOS 27.
- **Apple Intelligence:** غير متاح على iPhone 11. هناك يعمل AI فقط عبر خادم المستخدم.
- **Dynamic Island:** غير موجود على iPhone 11، فيظهر النشاط المباشر على شاشة القفل فقط.
- **الويدجت والمشاركة:** يحتاجان App Group موقّعاً. في البناء غير الموقّع يظهر الويدجت فارغاً.
- **تحويل العملات:** بسعر يدخله المستخدم، ولا أسعار من الإنترنت.
- **البحث بالمعنى:** متاح فقط للغات التي لها نموذج على الجهاز.
- **لا مزامنة iCloud:** البيانات تبقى على الجهاز وفي نسخته الاحتياطية.
- **PiP:** يعرض بطاقات TaskLens فقط، ولا يعرض تطبيقات أخرى.

## 7. الحساب التجريبي (Demo account)

**غير مطلوب.** لا يوجد تسجيل دخول ولا خادم. لذلك لا ينطبق شرط حذف الحساب (البند 5.1.1(v)). حذف كل البيانات موجود في الإعدادات.

## 8. خطة لقطات الشاشة (Screenshot plan)

**الأجهزة:**
- 6.9" (iPhone 17 Pro Max أو 16 Pro Max)، وهو مطلوب.
- 6.5" اختياري.
- مرجع الاختبار iPhone 11 (6.1") لا يُطلب للمتجر.

**الإعدادات:**
- مجموعتان: الإنجليزية والعربية (RTL).
- الوضع الفاتح، ولقطة واحدة داكنة.

| # | الشاشة | الرسالة |
|---|---|---|
| 1 | Command Center مع البحث الذكي | «كل ما تعمل عليه في مكان واحد» |
| 2 | مساحة عمل مع جلسة نشطة | «جلسات تتذكر سياقك» |
| 3 | Lens على صورة سعر مع الإجراءات المقترحة | «افهم ما تراه، على جهازك» |
| 4 | نافذة PiP فوق تطبيق آخر | «ملاحظاتك عائمة أثناء العمل» |
| 5 | سير عمل: مشاركة رابط ← حفظ في البحث | «أتمتة بتأكيد منك» |
| 6 | النشاط المباشر على شاشة القفل والويدجت | «جلستك في لمحة» |
| 7 | الإعدادات: الخصوصية، تصدير، حذف كل شيء | «بياناتك لك» |

**قواعد:**
- محتوى تجريبي فقط، بلا بيانات حقيقية.
- لا تُعرض Screen Lens على أنها متاحة لكل الأجهزة. إن عُرضت، يُكتب «iOS 27+».
- يمكن توليد اللقطات بـ XCUITest مع `-TaskLensUITestStore` لبيانات ثابتة.

## 9. مسودة وصف التطبيق (App description draft)

**English**

> **TaskLens — work in context**
>
> TaskLens keeps everything you're working on together: notes, links, documents, prices and text, organized into workspaces and sessions you can pause and resume.
>
> • **Lens:** read text, links, prices, dates and codes from text, photos and PDFs, then act on them. All analysis happens on your iPhone.
> • **Smart Search:** find "prices I saw yesterday" or "my study PDF" across notes, links, documents and saved text.
> • **Picture in Picture:** keep a note or result floating while you use other apps.
> • **Workflows:** "share a link → save to Research". Steps that use AI always ask first.
> • **Widgets, Live Activities and Siri Shortcuts.**
> • **Optional AI:** Apple Intelligence on supported devices, or your own server. Off until you turn it on, and you always see what will be sent.
>
> **Private by design:** no account, no tracking, no analytics. Your data stays on your device. Export or delete everything at any time.
>
> Screen Lens requires iOS 27 or later. Apple Intelligence requires a supported device.

**العربية**

> **TaskLens: اعمل ضمن سياقك**
>
> يجمع TaskLens كل ما تعمل عليه: ملاحظات وروابط ومستندات وأسعار ونصوص، منظّمة في مساحات عمل وجلسات توقفها وتستأنفها متى شئت.
>
> • **العدسة:** تقرأ النصوص والروابط والأسعار والتواريخ والرموز من النص والصور وملفات PDF، وتقترح ما تفعله بها. كل التحليل على جهازك.
> • **البحث الذكي:** ابحث عن «الأسعار التي شاهدتها أمس» أو «PDF الخاص بالدراسة».
> • **صورة داخل صورة:** ملاحظتك عائمة وأنت في تطبيق آخر.
> • **سير العمل:** «شارك رابطاً ← احفظه في البحث». الخطوات التي تستخدم الذكاء الاصطناعي تطلب موافقتك دائماً.
> • **ويدجت وأنشطة مباشرة واختصارات Siri.**
> • **ذكاء اصطناعي اختياري:** على الجهاز حيث يتوفر، أو خادمك الخاص. لا يعمل إلا إذا فعّلته، وترى دائماً ما سيُرسل.
>
> **الخصوصية أولاً:** بلا حساب ولا تتبع ولا تحليلات. بياناتك على جهازك، وتصدّرها أو تحذفها متى شئت.
>
> عدسة الشاشة تحتاج iOS 27 أو أحدث.

## 10. قائمة مخاطر المراجعة (Review-risk checklist)

| # | البند | الحالة | الخطر | ما يلزم |
|---|---|---|---|---|
| 1 | 2.3 / تقني: أيقونة التطبيق | ❌ غير موجودة | يمنع الرفع | تصميم أيقونة 1024×1024 |
| 2 | معرّفات Bundle وApp Group | ❌ مؤقتة | يمنع الرفع | معرّفات حقيقية وتوقيع |
| 3 | 2.5.4 وضع `audio` لـ PiP دون صوت | ⚠️ | **عالٍ** | ملاحظة المراجعة أعلاه. إن رُفض، الخيار هو تعطيل الخلفية لـ PiP. |
| 4 | Screen Lens على iOS 27 (beta) | ⚠️ لم يُختبر على جهاز | متوسط | اختبار على iOS 27 قبل الإرسال، أو إخفاؤه حتى ذلك |
| 5 | وضع الخلفية `screen-capture` | ⚠️ | متوسط | التأكد أنه القيمة الصحيحة في SDK iOS 27 |
| 6 | تصنيف العمر: متصفح عام | ⚠️ | متوسط | الإجابة بـ Unrestricted Web Access (تصنيف أعلى) |
| 7 | 5.1.1 نصوص الصلاحيات | ✅ واضحة ومترجمة، والشرح يسبق الطلب | منخفض | — |
| 8 | 5.1.2 بيانات إلى طرف ثالث (AI) | ✅ معطّل افتراضياً، مع كشف قبل كل إرسال | منخفض–متوسط | تأكيد إجابة «لا نجمع» أو التصريح المتحفظ |
| 9 | سياسة الخصوصية | ❌ غير منشورة | يمنع الإرسال | نشر صفحة |
| 10 | 2.1 الاكتمال: ميزات «قريباً» | ⚠️ إجراءات «تذكير» و«تلخيص» و«إضافة جهة اتصال» و«اسأل AI» داخل بطاقة الإجراءات ما زالت تعرض «سيُضاف في تحديث لاحق». (التحويل صار يعمل في المرحلة 18.) | متوسط | إخفاؤها في نسخة المتجر أو إكمالها |
| 11 | 4.2 الحد الأدنى من الوظائف | ✅ | منخفض | — |
| 12 | Private APIs | ✅ لا يوجد. كل الأطر عامة. | — | — |
| 13 | تسجيل أو مراقبة مخفية | ✅ لا يوجد: إطار واحد، ومؤشر النظام، وزر إيقاف | — | — |
| 14 | الحافظة | ✅ بلا قراءة تلقائية | — | — |
| 15 | تتبع، تحليلات، SDKs | ✅ لا يوجد | — | — |
| 16 | Privacy manifests | ✅ في الحزم الثلاث، ويتحقق CI من وجودها | — | — |
| 17 | التشفير | ✅ معفى | — | — |
| 18 | أداء أمر Release archive | ⏳ في CI الحالي | — | انظر تقرير المرحلة 16 |
| 19 | اختبار على جهاز حقيقي | ❌ لم يحدث | متوسط | TestFlight على iPhone 11 |

## ما تغيّر في الكود في هذه المرحلة

- `a9daca4`: شرح قبل طلب الكاميرا («استخدام الكاميرا للعدسة؟» مع «متابعة» و«ليس الآن»)، بالعربية والإنجليزية.
- من المرحلة 16 (`2da7e19`): شرح الكاميرا المرفوضة مع رابط الإعدادات، وتنبيه الأنشطة المباشرة المتوقفة.
