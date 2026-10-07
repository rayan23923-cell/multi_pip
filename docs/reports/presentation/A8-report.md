# Delivery Report: A8

**PHASE:** A8, PowerPoint Technical Audit (decision only)

**STATUS:** Done on the iPhone 11 simulator (iOS 26.5, probe run 37191763333). Not checked on a real device.

**CODE CHANGES:** None in the app or its packages: `App/` and `Packages/` are unchanged since A7. The phase added:
- the audit document `docs/presentation/A8-pptx-audit.md`, with 7 evidence images;
- test-deck scripts in `Tools/PPTXAudit/`;
- an isolated probe project, `Tools/PPTXAudit/Probe`;
- a manual workflow, `.github/workflows/pptx-audit.yml`.

No dependency was added.

## APPROACHES INVESTIGATED

There were 7 options, A–G. The evidence came from:
- the probe on the simulator;
- a LibreOffice reference render;
- a review of documentation and repositories.

## OPTION A: Quick Look
- It previews `.pptx` as a scrolling page.
- It has no slide API: no count, no current slide, no navigation.
- Arabic letters join correctly, but the right-to-left order is wrong, and an app cannot fix that.
- Thumbnails are unreliable. The 10-slide deck failed after 63 s.
- **Rejected for presenting.**

## OPTION B: PPTX → PDF on the device
- Apple has no direct API for this.
- WebKit's print renderer at 960×540 produced exactly one page per slide.
- **Viable, but heavier than images.**

## OPTION C: PPTX → images
- WKWebView lays out one `div.slide` per slide. Each slide snapshots in a few milliseconds.
- **Recommended route.**

## OPTION D: PPTX → HTML
- WebKit's own HTML is not portable, because its images use `x-apple-ql-id://` addresses.
- JS renderers would add a dependency and their Arabic support is unverified.
- **Rejected.**

## OPTION E: Open-source renderers
- **LibreOffice/Collabora:** MPL licence, about 335 MB.
- **Native Swift:** immature.
- **JS:** Apache or MIT licences, new dependencies.
- **All rejected.**

## OPTION F: Server conversion
- It breaks offline-first and means uploading user files.
- **Reference only.**

## OPTION G: The user exports a PDF
- PowerPoint and Keynote can export a PDF on the iPhone, and TaskLens already presents PDFs (A3).
- **Fallback, and usable from day one.**

## ARABIC SUPPORT
- **Shaping and Arabic-Indic digits:** correct in WebKit and Quick Look.
- **Right-to-left direction:** lost in both.
  - Sentences come out in the wrong order and punctuation lands on the wrong side.
  - In mixed text, the English words move.
- **The fix:** adding one CSS line (`unicode-bidi: plaintext`) corrects it fully in WebKit. Slides 9 and 10 then match the correct reference.
- **LibreOffice:** everything correct.
- **Fonts:** Calibri, Georgia and Arial Black fall back to a serif font on iOS.

## VISUAL FIDELITY
WebKit rates **Good** on 13 slides: text, images, shapes, table, chart, background, layout, 40 objects and the complex layout.
- **Fonts:** Acceptable, because they fall back.
- **Arabic:** Poor without the fix, Good with it.
- **Slides with speaker notes:** Unsupported, because WebKit rejected the file.

LibreOffice rates Excellent on all 15.

## ANIMATIONS
- None of the approaches play animations or transitions; the slides come out static.
- Video and audio were not tested and should be treated as unsupported.

## SPEAKER NOTES
- They are never shown.
- WebKit **rejected both test decks that had notes** (error 912). Those files were made by python-pptx, so whether decks saved by PowerPoint or Keynote are affected is **unverified**.

## SECURITY
- WebKit rejected the ZIP bomb and the non-ZIP file in about 2 s, with no crash and no growth in app memory. Parsing runs in WebKit's own process.
- The XXE file leaked nothing: the entity expanded to empty text.
- `.pptm` files open, and macros never run on iOS.
- Quick Look's `canPreview` says yes even to garbage.
- **Guards needed in A9:**
  - a file size cap;
  - a ZIP pre-check;
  - a web view with no stored data and no network or navigation;
  - discarding the web view after conversion.

## LICENSE
- WebKit and Quick Look are system frameworks, so there is no licence cost.
- Third-party options are MPL, AGPL or commercial; none is needed.

## APP STORE
- WebKit and Quick Look are public APIs, so they are safe.
- A server option would need privacy-label disclosure.

## PERFORMANCE
- **Simulator:** loads take 1.5 s for 10 slides, 2 s for 50, and 4.5–7 s for 100. App memory stays flat at about 51 MB.
- **iPhone 11 (estimate):** 1–3× slower.
- **LibreOffice reference:** 1.7 s, 3.0 s and 5.1 s.

## STORAGE
A 1920 px JPEG per slide is about 150–300 KB (estimate):

| Slides | Storage (estimated) |
|---|---|
| 10 | 2–3 MB |
| 50 | 8–15 MB |
| 100 | 15–30 MB |

## WEB RECEIVER COMPATIBILITY
Static slide images are the best fit. Any browser can show them, and the original file never leaves the phone.

## RECOMMENDED APPROACH
1. Convert on the device with WKWebView.
2. Apply the Arabic CSS fix.
3. Check that the slide count matches the deck.
4. Store one image per slide and present them through the existing image path.

## ALTERNATIVE
Use WebKit's print renderer to make a PDF, one page per slide, and present it through A3.

## FALLBACK
When conversion fails, ask the user to export a PDF from PowerPoint or Keynote (option G).

## MVP DECISION
- **In the MVP:**
  - `.pptx` and `.ppsx` turned into static images;
  - Arabic fixed;
  - the PDF fallback.
- **Not in the MVP:**
  - animations and media
  - speaker notes
  - live links
  - `.ppt` and `.pptm`
- **Condition:** before A9, a real iPhone must show that genuine PowerPoint and Keynote decks **with notes** convert. If they don't, the MVP becomes option G only.

## ARCHITECTURAL IMPACT
- The path becomes PPTX → slide images → the image loader → `PresentationSlide`.
- **Unchanged:** the engine, state, Auto Play, sessions and the receiver contract.
- **New in A9:**
  - a small ZIP reader with no dependency;
  - a converter in the UI layer;
  - a folder per imported deck.

## TEST DOCUMENT RESULTS
**15-slide deck:**
- WebKit rejected the full deck.
- One slide at a time, 13 of 15 render. Slides 1 and 12, the ones with notes, are rejected.
- Quick Look's preview stayed on "Loading…".
- LibreOffice rendered 15 of 15 correctly.

**10, 50 and 100 slides:** all load in WebKit.

**Hostile files:** handled safely.

Images are in `docs/presentation/A8/`.

## GIT COMMIT
6 commits on `claude/project-thread-0s4dmt`, all prefixed `presentation/A8-pptx-audit`:
- **5 probe commits:** the first probe, followed by 4 fixes and extensions while it ran on CI.
- **1 docs commit:** `8b11478 presentation/A8-pptx-audit: audit report and MVP decision`.

## KNOWN LIMITATIONS
- Simulator only. No decks written by PowerPoint or Keynote were tested.
- WebKit's slide layout is not a documented contract.
- WebKit's own memory use was not measured.
- Embedded fonts, SmartArt, video, 4:3 slides and `.ppsx` were not tested.

## NEXT PHASE
A9 (PowerPoint). Not started; it waits for approval and for the real-device check on decks with notes.
