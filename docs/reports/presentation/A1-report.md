# TaskLens — A1 Presentation Data Model: Delivery Report

- **PHASE:** A1 — Presentation Data Model (Track A)
- **STATUS:** Done
- **DATE:** 2026-10-03

## FILES CHANGED

All files are new. No existing file was touched.

- `Packages/TaskLensKit/Sources/TLDomain/Presentation.swift`
- `Packages/TaskLensKit/Sources/TLDomain/PresentationState.swift`
- `Packages/TaskLensKit/Tests/TLDomainTests/PresentationTests.swift`

## FEATURES ADDED (models only)

**`PresentationSourceType`**
- Values: pdf, image, powerpoint, unknown.
- `isSupported` is true only for pdf and image.
- powerpoint exists only as a name for later phases (A8/A9). Nothing imports it.

**`PresentationSlideSource`**
- `.pdfPage(documentID, pageIndex)` or `.image(documentID)`.
- Later sources (PowerPoint, Web) are added as new cases.

**`PresentationSlide`**
- `index` is zero-based; `displayNumber` is one-based.

**`PresentationDocument`**
- Fields: id, documentID, title, sourceType, slides, `slideCount`, createdAt.
- `.pdf(document, pageCount:)` gives one slide per page.
- `.images([documents])` keeps the order given.
- Both reject empty input and the wrong file kind, using existing errors that already have translations.
- References existing documents; no files are copied.

**`PresentationState`**
- Phases: idle, loading, ready, playing, paused, completed, error.
- Fields: `currentSlide` (zero-based, 0…slideCount−1) and `slideCount`.
- `displaySlideNumber` gives 1…slideCount for the UI.
- Transitions: beginLoading, finishLoading, fail, start (from paused this also resumes), pause, stop, next, previous, goTo(slide:).
- A transition that doesn't apply returns false and changes nothing.
- No timers and no file loading; that stays for A2.

**Design notes**
- `currentSlide` lives only in `PresentationState`, not in `PresentationDocument`, so there is one source of truth.
- `Document.lastReadPage` is never read or written. A test checks this.
- Everything is Codable, so A7 can store it later without changing the models.

## TESTS

20 new tests in 2 suites. Parameterized cases: 1/10/50/100 pages for PDF, 10/50/100 slides for playing through to the end.

## BUILD

Passed on CI run 44 (commit 9c62d3f): Xcode 26.6, iPhone 11 simulator, iOS 26.5. The new files compile with no warnings.

## TEST RESULTS (run 44)

- **TaskLensKit:** 357/357 passed (Mac and simulator), including all Presentation tests.
- **TaskLensUI:** 125/125 passed.
- **App unit tests:** 15/15 passed.
- **UI tests:** 54 passed, 2 failed, 3 skipped.
  - Failed: the 2 old Dynamic Type audits on Screen Lens (`HardeningUITests`). These were failing before A1 and A1 touches nothing in the UI.
  - Skipped: the 3 known skips with stated reasons (Safari share, PiP on simulator, YouTube on simulator).

## REAL DEVICE

Not needed for A1. The phase has models only, with no UI or system APIs.

## REGRESSION

The PDF reader is unaffected:
- No code in the PDF reader, Document or DocumentService changed.
- `ToolsUITests.testDocumentViewersOpenSearchAndPage` passed (open, search, page navigation).
- `SystemIntegrationUITests.testDeepLinksOpenTools` passed.

## GIT COMMIT

Branch `claude/project-thread-0s4dmt`:
- `0b0c269` presentation/A1-data-model
- `9c62d3f` presentation/A1-data-model: a follow-up fix. Swift Testing's `#expect` doesn't accept mutating calls inside it, which broke the test build on CI run 43.

## KNOWN ISSUES

- The 2 old Dynamic Type audits (Screen Lens).
- A1 is in two commits rather than one because of the test fix. Both carry the same phase name.

## LIMITATIONS

- No presentation exists for the user yet: no engine, no UI.
- PowerPoint is only a type name until A8 proves a path.
- An image presentation's `documentID` points at its first image. Each slide carries its own image ID.

## NEXT PHASE

A2 — Presentation Engine, waiting for approval.
