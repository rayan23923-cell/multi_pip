# A6 — Auto Play · Delivery Report

**PHASE:** A6 — Auto Play
**STATUS:** Finished on CI (run 54). Still waiting on the real-device check and approval.

## FILES CHANGED
Commit 8dd386d: 9 files, +1151 / −7.

- **New:** `TLCoreServices/Presentation/PresentationAutoPlayer.swift`, the auto-play capability.
  - It runs on top of `PresentationEngine` and changes nothing inside the engine.
- `PresentationFeature/PresentationModel.swift` gains:
  - an `autoPlayer` property
  - `toggleAutoPlay`, `stopAutoPlay` and `setAutoPlayInterval`
  - `didEnterBackground` and `didLeave`
  - a call that tells the player whenever the user changes slide by hand
- `PresentationFeature/PresentationView.swift` gains:
  - Play/Pause/Resume and Stop buttons in the control bar
  - an interval menu in the navigation bar
  - a custom-interval alert
  - background handling, the screen's idle timer, and stopping playback on leaving
- Strings: 8 new keys in English and Arabic, in `strings.py`, `L10nKey` and `xcstrings`.
- Tests:
  - `TLCoreServicesTests/PresentationAutoPlayerTests.swift`
  - `TaskLensUITests/PresentationModelTests.swift` (6 added tests)
  - `TaskLensAppUITests/PresentationUITests.swift` (2 added tests)

The A1–A5 code was not changed. The engine, state and loaders are untouched.

## FEATURES ADDED
- **Commands:** Play, Pause, Resume and Stop.
- **Intervals:** 5, 10, 15, 30 or 60 seconds, or a custom value from 1 to 3600 seconds.
  - The default is 10 seconds.
  - The custom field also accepts Arabic-Indic digits.

## BEHAVIOUR
- **Play** starts from the current slide. If the presentation has completed, an explicit Play starts again from slide 1.
- **Pause** cancels the countdown, so nothing advances.
- **Resume** continues from the same slide with a full interval.
- **Stop** ends playback and returns to ready; the current slide stays.
- **Last slide:** one more interval completes the presentation and leaves the last slide showing. It does not loop.
- **Manual navigation while playing:** the new slide gets a full interval. While paused, nothing starts.
- **Changing the interval while playing** applies the new interval immediately.
- **Background:** playback pauses, because iOS suspends the app.
  - On return it waits for Resume on the same slide and does not jump.
- **Leaving the screen** stops playback.
- **Reopening** creates a new engine and a new player, with no old countdown.
- **Screen lock:** the screen stays awake (`isIdleTimerDisabled`) only while playback is running. The setting is cleared when playback stops, pauses, or the screen closes.

## TIMER SAFETY
- **One countdown at a time:**
  - The player owns at most one countdown `Task`.
  - Every command cancels the old countdown before starting a new one.
  - A generation number stops a countdown that has already been replaced from moving a slide.
- **No leaks:** the countdown holds the player only weakly.
  - If the player is released, its countdown ends instead of sleeping again (tested).
- **Never more than one live countdown:** tests track this as the number of countdowns waiting at the same moment. The maximum seen was 1 in every test, including 50 rounds of rapid mixed commands.

## lastReadPage
Auto play never reads or writes it. Tested at two levels:
- **Core:** a 20-page PDF with reading page 7. After play, ticks, pause, resume and stop, the stored document is identical.
- **Screen:** the reader is on page 2, auto play runs to the end, and a reopened reader is still on page 2.

## TESTS
**Core (`Presentation auto play` suite):** all pass, both on the Mac host and on the iPhone 11 simulator.
- Play, pause, resume and stop
- 5-second and other preset intervals
- Several slide transitions
- Last slide; a single-slide presentation
- Repeated Play and rapid commands
- A replaced countdown cannot advance
- Manual navigation
- Interval clamping
- 10, 50 and 100 slides
- Dropping the player; reopening
- One real 1-second timer
- `lastReadPage`

**Screen model:** 6 new tests, all pass.
- The button state follows playback
- Auto play runs to the last slide and stops
- Background pauses; leaving stops
- Manual navigation keeps playback going
- `lastReadPage` unchanged
- Reopening starts without playback

**UI, iPhone 11 simulator:** 2 new tests, both pass.
- Play with a real 5-second interval, then pause (nothing moves for 8 s), resume, stop (nothing moves), and play to the end (it stays on slide 4 and does not loop).
- Home button: nothing moves while away, and the app returns paused. Leaving and reopening shows slide 1 with no playback for 12 s.

**Performance:** stepping through every interval costs 0.09 s of overhead for 10 slides, 0.42 s for 50 and 0.72 s for 100. Only one countdown exists at any time.

## BUILD
- The app and all packages build on CI run 54 (macos-26, Xcode 26.6, iPhone 11 on iOS 26.5).
- Run 53 failed to compile because a test argument read a main-actor constant. Making the constants `nonisolated` fixed it, and the fix was amended into the same commit.

## REAL DEVICE
**Not done yet; it needs the user.** Steps:
1. Codemagic: run `device-lab-ipa` on `claude/project-thread-0s4dmt`, then install the IPA with Sideloadly.
2. Open a PDF, choose ⋯ › Present, set the timer menu to 5 seconds, and press ▶.
   - Slides should advance every 5 seconds.
3. Test the controls:
   - **⏸:** nothing moves.
   - **▶:** playback continues from the same slide.
   - **⏹:** playback stops.
4. Play to the end. It should stay on the last slide.
5. While playing, press Home, wait, and return. It should be paused on the same slide.
6. While playing, go Back and present again. It should start on slide 1 with no playback.
7. Leave a 60-second interval running. The screen should not lock while playback runs.
8. Try a custom interval typed in Arabic digits, and Go to Slide with Arabic digits.

## REGRESSION (run 54)
- **TaskLensKit:** 409 tests pass on the host, and the same 409 pass on the simulator.
- **TaskLensUI:** 141 tests pass. The 2 known QR issues on the VM simulator are older than this phase.
- **App UI:** 59 pass, 3 fail, 3 skipped. All A5 and A6 presentation tests pass.
  - The 2 failures that predate this work are the Dynamic Type audits on the scrolled Lens screen.
  - The 3rd failure is the control test `testReaderKeepsItsPageAfterVisitingLens`, covered under KNOWN ISSUES.
  - The 3 skips also predate this work: Safari share, PiP on the simulator, and YouTube embedding.
- QA06 and AIUITests pass.

## GIT COMMIT
`8dd386d presentation/A6-autoplay: advance slides on a timer`, one commit on top of A5 (2988070).

## KNOWN ISSUES
1. **The PDF reader sometimes reopened on page 1.** This bug predates A5 and A6.
   - **Cause** (found 2026-10-04): saving the reading page and the search indexer saving the PDF's text could both change the same document at once. When they did, the second save erased the first.
   - **Fix:** in progress as its own commit, `fix/pdf-reader-page`. Document changes now run one after another.
   - **Status:** final CI is running. A first attempt (ignoring PDFKit's page reports) did not help and was removed.
   - **A6 code is not affected.**
2. **Go to Slide (A5) may ignore Arabic-Indic digits.** Check this on the device.

## LIMITATIONS
- Playback does not run in the background; iOS suspends the app, so it pauses.
- The interval is not saved between presentations; each one starts at 10 seconds.
- There is no looping, by design.

## NEXT PHASE
A7 — Presentation session. Not started; it waits for approval.
