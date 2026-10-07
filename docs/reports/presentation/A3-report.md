# Delivery Report: A3 — PDF Presentation

- **PHASE:** A3 — PDF Presentation (Track A)
- **STATUS:** Done
- **DATE:** 2026-10-03

## FILES CHANGED

Two new files. No existing file was touched, and the PDF reader is unchanged.

- `Packages/TaskLensKit/Sources/TLCoreServices/Presentation/PDFPresentationLoader.swift`
- `Packages/TaskLensKit/Tests/TLCoreServicesTests/PDFPresentationTests.swift`

## FEATURES ADDED

`PDFPresentationLoader`, the A2 `PresentationLoading` source for PDFs. The flow is PDF → `PresentationDocument` → `PresentationEngine`. There is no UI.

## PDF LOADING

**How a PDF is loaded**
1. Fetch the imported `Document` through the existing `DocumentService` (`document(id:)`, `fileURL(for:)`).
2. Reject documents that are not PDFs.
3. Open the file with Core Graphics (`CGPDFDocument`) and read the page count.
4. Build the presentation with the existing A1 factory `PresentationDocument.pdf(_:pageCount:createdAt:)`. Each page becomes one slide, in page order.

**Failures**
Failures go through the A2 error mechanism:

| Case | Engine result |
|---|---|
| Unknown document | `error(.unreadable)` |
| Not a PDF | `error(.unsupportedSource)` |
| Damaged file | `error(.unreadable)` |
| Password-protected file | `error(.unreadable)` |
| PDF with no pages | `error(.unreadable)` |

A PDF with no pages ends up as unreadable because Core Graphics refuses to open it at all; this was confirmed on CI.

**Why Core Graphics, not PDFKit**
- TaskLensKit has no UI frameworks by design, and PDFKit on iOS pulls in UIKit.
- PDFKit lives in the UI feature modules. Putting the loader there would make a future Presentation feature depend on the Documents feature, which breaks the "features don't depend on each other" rule.
- Core Graphics reads the same file that PDFKit renders. Rendering in A5 will use PDFKit.

**Read-only**
- The loader never calls `markOpened` or `setLastReadPage`.
- The reader's `lastReadPage` and `lastOpenedAt` stay exactly as they were.

## SLIDE REPRESENTATION

- Each slide is the existing A1 `PresentationSlide` with source `.pdfPage(documentID, pageIndex:)`.
- `pageIndex` is zero-based and equals the slide index.
- That is enough for the A5 UI to open the document with PDFKit and draw the page at `pageIndex`.
- No images or copies of the page are stored.

## TESTS

The "PDF presentation" suite has 7 tests and 10 runs. The tests generate real PDFs and import them through `DocumentService`.

**Loading**
- `onePageBecomesOneSlideInOrder` with 1, 3, 10 and 50 pages:
  - The page count matches.
  - Each slide points to its own page.
  - Every page in the PDF has a different width, and the test checks that each slide's page in the file has the expected width. This proves the order is correct.
- `damagedFileIsUnreadable`
- `pdfWithoutPagesCannotBePresented`
- `otherKindsAreUnsupported`
- `unknownDocumentIsUnreadable`

**Engine**
- `loadedPDFDrivesTheEngine` covers 10 pages: first slide, next, previous, goToSlide, and both boundaries (previous at the first slide; next and goToSlide past the last slide).

**Separation**
- `presentingAndReadingKeepTheirOwnPositions`:
  - The reader is on page 20.
  - Presenting starts at slide 5 and then moves to slide 13.
  - The stored document is unchanged, field for field.
  - The reader then moves to page 26, and the presentation stays on slide 13.

## BUILD

Passed on CI run 48, commit 313c290 (Xcode 26.6, iPhone 11 simulator). The changed files compile with no warnings.

## TEST RESULTS (run 48)

| Target | Result |
|---|---|
| TaskLensKit | 381/381 passed (Mac and simulator), including all of "PDF presentation" and the A1/A2 suites |
| TaskLensUI | 125/125 passed |
| App unit tests | 15/15 passed |
| UI tests | 54 passed, 2 failed, 3 skipped |

- The 2 UI failures are the old Dynamic Type audits (Screen Lens).
- The 3 skips are the known simulator skips.
- QA06, which failed once on run 45, passed this time.

## REGRESSION

- No changes to the PDF reader, Document or DocumentService.
- `ToolsUITests.testDocumentViewersOpenSearchAndPage` passed: open, search and page navigation in the PDF reader.
- `SystemIntegrationUITests.testDeepLinksOpenTools` passed.
- `git show --stat` lists only the 2 new files.

## GIT COMMIT

`313c290` presentation/A3-pdf, one commit.

- The commit was amended twice before this run to fix the zero-page test fixture. Runs 46 and 47 failed only on that test.
- A1/A2 commits were not touched.

## KNOWN ISSUES

- The 2 old Dynamic Type audits.
- A PDF with no pages reports as "unreadable" rather than "empty", because the system will not open it.

## LIMITATIONS

- There is no UI yet, so users can't present a PDF yet (that comes in A5).
- No rendering or thumbnails yet.
- Password-protected PDFs are not supported (no password prompt).

## NEXT PHASE

A4 — Image Presentation, waiting for approval.
