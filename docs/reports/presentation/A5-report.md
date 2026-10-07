# A5 — Presentation UI · Delivery Report

**PHASE:** A5 — Presentation UI
**STATUS:** Done in CI. Waiting on the real-device check and approval.

## FILES CHANGED (commit 2988070, 14 files, +1042 / −1)
- New module `Packages/TaskLensUI/Sources/PresentationFeature/`
  - `PresentationModel.swift`: wraps `PresentationEngine`, loads the PDF or images, and decodes images on demand.
  - `PresentationView.swift`: the screen, the controls, `PDFSlideView` (PDFKit, UI layer only) and `ImageSlideView`.
- `TLNavigation/AppRoute.swift`: `.presentation(PresentationRequest)` with `.pdf(DocumentID)` and `.images([DocumentID])`.
- `App/TaskLens/RootView.swift`: maps the route to the screen.
- `DocumentsFeature/PDFViewerView.swift`: More menu › **Present**.
- `DocumentsFeature/DocumentLibraryView.swift`: toolbar **Present Images** button, shown only when there are images.
- `scripts/strings.py`, `L10nKey.swift`, `Localizable.xcstrings`: 16 keys in English and Arabic.
- `Packages/TaskLensUI/Package.swift`, `project.yml`: register the new module.
- `App/TaskLens/SampleDocuments.swift`: test-only seed `-TaskLensSeedPresentationImages`, which adds three slide PNGs.
- Tests:
  - `TaskLensUITests/PresentationModelTests.swift`
  - `App/TaskLensAppUITests/PresentationUITests.swift`

A1–A4 code is untouched. The PDF reader gains only the menu item.

## FEATURES ADDED
- A presentation screen for PDFs and image sets.
- ◀ / "Slide N / M" / ▶ control bar.
- Tapping the counter opens Go to Slide.
- Tapping the slide shows or hides the controls.

## PDF UI
- PDFKit `PDFView` in single-page mode, fit to the space, with no scrolling or zoom.
- The page changes only through the engine.
- The PDF opens on slide 1 regardless of the reading page.

## IMAGE UI
- Each image is decoded when its slide appears, at the screen's longest side × display scale, using an Image I/O thumbnail off the main thread.
- Images are shown aspect-fit on black.
- Slides follow the library order (newest first).

## NAVIGATION
- Navigation runs only through engine commands (`next`, `previous`, `goToSlide`); `PresentationState` is never written directly.
- Neither end wraps: the button is disabled and the command does nothing.
- Go to Slide ignores numbers out of range.

## SLIDE COUNTER
- The counter is one-based ("Slide 3 / 10"); VoiceOver reads "Slide 3 of 10".
- Internally the index stays zero-based.

## LOADING STATE
- A `ProgressView` with "Loading presentation…".
- Each image slide shows its own spinner while it decodes.

## ERROR STATE
- Errors use the existing `TLEmptyState`:
  - empty
  - unsupported (wrong kind)
  - unreadable (missing, damaged or locked PDF, unreadable image)
- If a single slide fails to render, it shows an inline "This slide could not be shown" without crashing.

## ACCESSIBILITY
- Every control has a label. The counter has a hint ("Go to Slide").
- The slide is one image element. Its label is the slide number, its value is the page or image name, and it has a named action to show or hide controls.
- Arabic and RTL use automatic chevron mirroring.
- No hard-coded strings. The audit failures are the old Lens ones only.

## PERFORMANCE
- Only the current slide is rendered: one PDF page or one decoded image.
- Images are never decoded at full size (tested: 1600×900 → 400×225).
- Tested sizes:
  - PDF navigation at 1, 3, 10 and 50 slides (model tests).
  - Images at 1, 3 and 10 (model tests).
  - 100 images at the loader level in A4.
- **Gap:** no timing measurement in the UI layer, and no 100-slide UI test.

## TESTS
- **Model tests: 13 cases, all pass.**
  - PDF opens on slide 1 and stays in bounds (1/3/10/50).
  - Go to Slide is one-based and ignores out-of-range numbers.
  - `lastReadPage` stays 3 after presenting, and a reopened reader is on page 3.
  - Image order is kept (1/3/10).
  - Images are downsampled.
  - Missing document → unreadable; empty list → empty; wrong kind → unsupported.
  - A damaged image doesn't crash.
  - The route carries the request.
- **UI tests: 4, all pass.**
  - PDF present: first/next/previous/last, disabled ends, counter, Go to Slide, hide/show controls, and the reader keeps page 2 after return and after reopening.
  - Images in library order.
  - Rotation to landscape.
  - A control test: the reader keeps its page after visiting Lens.

## BUILD
CI run 52 on macos-26 (Xcode 26.6, iPhone 11 iOS 26.5 simulator). The app and all packages build.

## REAL DEVICE
**Not done yet; needs the user.** Steps:
1. Codemagic → run `device-lab-ipa` on branch `claude/project-thread-0s4dmt`.
2. Install the IPA with Sideloadly.
3. Import a PDF and a few photos.
4. PDF: open it, More (⋯) › Present. Check ◀ ▶, the counter, Go to Slide and tapping the slide.
5. Rotate the phone, send the app to the background, return.
6. Go back: the reader should be on the page you left it on.
7. Library: Present Images. Repeat steps 4–5.

## REGRESSION (run 52)
- **TaskLensKit:** 392 tests pass on the Mac host; 325+11+44+12 pass on the simulator.
- **TaskLensUI:** 135 tests pass. 2 known issues are pre-existing: QR on the VM simulator.
- **App UI tests:** 58 pass, 2 fail, 3 skipped.
  - The 2 failures are the old Dynamic Type audits on Lens scrolled (`Read the Screen`, `screenLens.unavailable`). They are not linked to A5.
  - The 3 skips are pre-existing: Safari share, PiP on the simulator, YouTube embedding.
- QA06 and AIUITests pass.
- The PDF reader and Screen Lens tests pass.

## GIT COMMIT
`2988070 presentation/A5-ui: presentation screen for PDFs and images` on `claude/project-thread-0s4dmt`. It is one commit on top of A4 (d26d7c6).

## KNOWN ISSUES
- **Intermittent page reset.** In run 51 the PDF test once saw the reader reopen on page 1 instead of page 2. It did not repeat in run 52; both the presentation test and the Lens control test passed. The cause is not proven. It may be the reader's PDFView reporting page 0 while off screen, which is pre-existing behaviour. Leave the control test in place to catch it.
- In run 51, QA06 and one AIUITests test failed once each. Both passed in run 52.

## LIMITATIONS
- No auto play, timer, PiP, Web Receiver, PowerPoint, Notes, Whiteboard or external display (out of scope for A5).
- Present Images uses every image in the library, in list order. There is no picker yet.
- Fullscreen stays inside the app: the status bar and home indicator hide only with the controls.

## NEXT PHASE
A6 — Auto play. Not started; waiting for approval.
