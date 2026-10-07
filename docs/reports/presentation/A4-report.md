# Delivery Report: A4 — Image Presentation

**PHASE:** A4 — Image Presentation (Track A)

**STATUS:** Done

**FILES CHANGED:** 2 new files. No existing file was touched, and A1, A2 and A3 are unchanged.
- `Packages/TaskLensKit/Sources/TLCoreServices/Presentation/ImagePresentationLoader.swift`
- `Packages/TaskLensKit/Tests/TLCoreServicesTests/ImagePresentationTests.swift`

**FEATURES ADDED:** `ImagePresentationLoader`, an A2 `PresentationLoading` source that takes ordered images and produces a PresentationDocument for PresentationEngine. There is no UI.

## IMAGE SOURCES

- **Infrastructure:** images come in through the existing import, `DocumentService.importData` / `importFile` (Files picker or Photos picker). Each one is stored as a `Document` of kind `.image`, with its file under `Documents/<UUID>.<ext>`, and is referenced by `DocumentID`. The loader reuses this and adds no new storage.
- **What the loader does:**
  1. Takes `[DocumentID]` in the caller's order, plus an optional title. With no title, it uses the first image's title.
  2. Fetches each document.
  3. Requires kind `.image`.
  4. Checks that the file is readable.
  5. Builds the presentation with the existing A1 factory `PresentationDocument.images(...)`.
- **Formats:** the importer accepts anything that conforms to `public.image`. The loader accepts whatever Image I/O can read.
  - Tested on CI with real files: JPEG, PNG, HEIC, GIF and TIFF all passed on both the Mac host and the simulator.
  - WebP: Image I/O can read it on iOS 14+ but cannot write it, so no test file could be made. Supported by the system, but not tested here.
  - Animated GIF: 1 slide, showing the first frame. There is no animation playback.
- **Failures** (through the A2 mechanism):
  - empty list → `error(.empty)`
  - non-image document → `error(.unsupportedSource)`
  - unknown ID → `error(.unreadable)`
  - corrupted or unreadable image → `error(.unreadable)`
  - If any one image fails, the whole load fails.

## ORDERING

- The supplied order is kept exactly.
- No sorting by name, import date, creation date or size.
- The same image may appear more than once if the caller lists it twice.

## SLIDE REPRESENTATION

- Uses the existing A1 `PresentationSlide` with `.image(documentID)`.
- Index is zero-based, 0…N−1.
- No image data is stored in the model, only the reference.

## ENGINE INTEGRATION

- The A2 engine is unchanged and doesn't know the source type.
- Tested: first slide, next, previous, goToSlide, the first and last boundaries, and stop.

## TESTS

The suite "Image presentation" has 11 tests and 20 runs:

| Area | Tests |
|---|---|
| Basic and large | 1, 2, 5, 10, 50 and 100 images |
| Order | Imported A,B,C,D and presented as C,A,D,B. Each file has a distinct pixel width, and the test checks that every slide's file is the expected image. |
| Duplicates | The same image twice |
| Formats | JPEG, PNG, HEIC, GIF, TIFF, animated GIF |
| Invalid input | Empty list, a text document, an unknown ID, a corrupted PNG |
| Engine | Navigation, boundaries, stop |
| Separation | Presenting leaves every stored document unchanged, including a PDF whose reader is on page 20 |

## BUILD

CI run 49 on commit d26d7c6 (Xcode 26.6, iPhone 11 simulator). The new files compile with no warnings.

## REGRESSION

**Results**

| Suite | Result |
|---|---|
| TaskLensKit | 392/392 passed (Mac and simulator), including all A1/A2/A3/A4 suites |
| TaskLensUI | 125/125 passed |
| App unit tests | 15/15 passed |
| UI tests | 54 passed, 2 failed, 3 skipped |

- **UI failures:** the 2 old Dynamic Type audits on Screen Lens, which predate A4.
- **Skips:** the 3 known simulator skips.
- **QA06** passed.

**Checks**
- PDF reader: `ToolsUITests.testDocumentViewersOpenSearchAndPage` passed.
- Deep links: `SystemIntegrationUITests.testDeepLinksOpenTools` passed.
- Diff reviewed: 2 new files only. No UI, timer, PiP or web code, and no new dependencies.

## PERFORMANCE

- Files are checked from the Image I/O header only (`kCGImageSourceShouldCache: false`). No pixels are decoded and nothing full-size is loaded.
- 100 images loaded in under a second on the Mac host.
- Decoding is left to the presentation UI (A5).

## GIT COMMIT

`d26d7c6` presentation/A4-image — one commit, green on its first CI run.

## KNOWN ISSUES

- The 2 old Dynamic Type audits.

## LIMITATIONS

- No UI, so users can't present images yet.
- No WebP test file.
- Animated images show their first frame only.
- One bad image fails the whole presentation; it is not skipped.
- Nothing yet lets the user pick images and order them. That needs UI and comes later.

## NEXT PHASE

A5 — Presentation UI, waiting for approval.
