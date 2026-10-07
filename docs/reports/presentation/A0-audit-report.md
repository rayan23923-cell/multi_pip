# TaskLens — Presentation Audit Report (A0)

**PHASE:** A0 — Audit (Track A, Presentation System)
**STATUS:** Done. Audit only; no code changed.
**FILES CHANGED:** None (this report only).
**TESTS:** None run. A0 changes no code, so the last CI result still applies (run 42, commit cbebc20).
**DATE:** 2026-10-03

---

## 1. Existing capabilities

| Area | What exists today | Where |
|---|---|---|
| Import | Files app picker (multi-select) and Photos picker (one photo per pick). Copies into `Documents/<UUID>.<ext>` with file protection, 200 MB limit. | `DocumentService.importFile/importData`, `DocumentLibraryView.swift:60,73` |
| Types | `FileKind`: image, pdf, text, document. Importable: pdf, image, plain text, source code, CSV, JSON, XML. | `TLDomain/ContextContent.swift`, `DocumentService.kind(for:)`, `importableTypes` |
| PDF | PDFKit viewer: page count, current page, next and previous, go to page, "Page X of Y" label, search with match stepping, text extraction, save to session, keep the current page in PiP, open in Lens. Resumes at `lastReadPage`. | `PDFViewerModel.swift`, `PDFViewerView.swift` |
| Images | Single-image viewer: decodes off the main thread, shows pixel size, save to session. No notion of a set of images or of order. | `ImageViewerModel.swift`, `ImageViewerView.swift` |
| PowerPoint | **None.** .ppt/.pptx/.key are rejected on import (`unsupportedContent`). No QuickLook. | — |
| Document model | `Document`: id, workspaceID, sessionID, title, file, `pageCount`, `lastReadPage` (zero-based), createdAt, lastOpenedAt, metadata. | `TLDomain/Document.swift` |
| Session resume | `SessionResumeState` remembers tool, documentID and page. PDF writes it through `ToolStateRecorder` on every page change. | `SessionResumeState.swift`, `SessionContentService.swift:182` |
| Action Engine | `.document` gives Save to session and Share. No presentation actions. | `ActionEngine.swift:160` |
| Routes | `AppRoute.pdf(DocumentID)`, `AppRoute.image(DocumentID)`. | `TLNavigation/AppRoute.swift:43-44` |
| Data control | Documents are in `Repositories`, export (`DataControl`) and Clear All. | `TLData/DataControl.swift` |
| External display | **None.** One `WindowGroup`, `UIApplicationSupportsMultipleScenes: false`. | `TaskLensApp.swift:38`, `project.yml:51` |
| Presentation code | **None.** The only "presentation" hit is `PiPPresentation` (PiP card state, unrelated). | `TLDomain/PiPCard.swift:103` |

## 2. Reusable components

- **DocumentService** for import, storage, file URLs, `markOpened(pageCount:)`, `setLastReadPage`. A presentation can point at an existing `Document` by `documentID` and needs no new storage for files.
- **PDFKit `PDFDocument`** for slide count and per-page rendering (`PDFPage.thumbnail(of:for:)`) for PDF slides.
- **PDFViewerModel's navigation logic** (clamped `goTo`, `canGoBack/canGoForward`) is the same shape the Presentation Engine needs. Reuse the pattern, not the class, so the PDF viewer stays untouched.
- **ImageViewerModel's off-main decoding** for image slides.
- **ToolStateRecorder / SessionResumeState** for A7 resume (document plus page already supported).
- **Localization pipeline** (`scripts/strings.py` → L10nKey), including `L10n.format` for "12 / 48".
- **Repositories + DataControl** pattern if A7 adds a stored presentation session.

## 3. Conflicts and risks

1. **Name clash:** `PiPPresentation` already exists in TLDomain. New types should use the `Presentation*` prefix from the spec (`PresentationDocument`, `PresentationSlide`, `PresentationState`) and never reuse `PiPPresentation`. No compile clash, but keep the two apart in naming and in modules (Track A must not depend on PiP).
2. **Two "current page" sources:** `Document.lastReadPage` (reading position) vs the new `currentSlide`. Decision needed in A1/A7: either keep them separate (presenting does not move the reading position) or share one. Recommendation: keep separate.
3. **Index base:** `lastReadPage` is zero-based; the UI shows one-based. The spec's `currentSlide` must state its base. Recommendation: zero-based in the model, one-based only in the UI, matching the PDF viewer.
4. **`FileKind` has no powerpoint case** and `importableTypes` blocks .pptx. Adding `powerpoint` to `sourceType` in A1 is fine as a value, but import stays blocked until A8 proves a public-API path. A1 must not widen `importableTypes`.
5. **Images are single documents.** A slideshow of images needs an ordered list of `DocumentID`s; nothing models that today.
6. **Photos picker picks one photo at a time.** Multi-image slideshows from Photos would need multi-selection (a change to the import flow; flagged, not done).
7. **External display needs scene support.** Today multiple scenes are off. A10 must check whether an external-display scene role works with the current SwiftUI `WindowGroup` app without reworking the app's scene setup.
8. **Existing failing UI tests:** the 2 Dynamic Type audits on Screen Lens still fail. Unrelated to presentations, but they keep the full UI run red.

## 4. Missing components

- `PresentationDocument`, `PresentationSlide`, `PresentationState` (A1).
- `PresentationEngine`: load/start/stop/next/previous/goToSlide and the states idle/loading/ready/playing/paused/completed/error (A2).
- PDF slide source (A3) and ordered image slide source (A4).
- Presentation UI with "12 / 48" counter (A5), auto play with timer (A6).
- Presentation session persistence: documentID, currentSlide, autoPlay, interval, lastViewedAt (A7).
- Any PowerPoint path (A8 investigation first; QuickLook preview is the likely only public option, and it does not expose slides).
- External display scene (A10/A11).
- Unit tests for any of the above (there are no presentation tests).

## 5. Files involved

**Read in this audit:**
- `Packages/TaskLensKit/Sources/TLDomain/Document.swift`, `ContextContent.swift`, `SessionResumeState.swift`, `PiPCard.swift`, `Workspace.swift`
- `Packages/TaskLensKit/Sources/TLCoreServices/DocumentService.swift`, `SessionContentService.swift`, `ActionEngine.swift`
- `Packages/TaskLensKit/Sources/TLData/DataControl.swift`, `Repositories.swift`
- `Packages/TaskLensUI/Sources/DocumentsFeature/*` (library, PDF viewer, search indexer)
- `Packages/TaskLensUI/Sources/ImageViewerFeature/*`
- `Packages/TaskLensUI/Sources/TLNavigation/AppRoute.swift`
- `App/TaskLens/TaskLensApp.swift`, `project.yml`

**Likely touched in A1 (proposal, not done):** new file(s) in `TLDomain` for the three model types plus a unit test file in `TLDomainTests`. Nothing else.

## 6. RESULTS

- PDF: solid base, reusable for A3.
- Images: single-image only; ordering is missing.
- PowerPoint: not supported at all today.
- No presentation or external display code exists, so A1 starts clean with one naming conflict to avoid.

## 7. KNOWN ISSUES

- The 2 Dynamic Type audit UI tests (Screen Lens) still fail; unrelated.
- YouTube→PiP device log still pending (Track B context, not part of A0).

## 8. NEXT PHASE

**A1 — Presentation data model** (`presentation/A1-model`), waiting for your approval. Two decisions to confirm with it:
1. Keep `currentSlide` separate from `Document.lastReadPage` (recommended).
2. `currentSlide` zero-based in the model, shown one-based in the UI (recommended).
