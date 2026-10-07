# TaskLens — YouTube → PiP: Feasibility + Prototype

Date: 2026-10-03 · Branch `claude/project-thread-0s4dmt` · Last commit `cbebc20` · CI runs 40 (build and unit tests) and 42 (UI tests)

## Final verdict

| Path | Result | Main evidence |
|---|---|---|
| **A** YouTube → TaskLens → Native PiP | **NOT SUPPORTED** | `AVPictureInPictureController.ContentSource` only accepts `AVPlayerLayer`, `AVSampleBufferDisplayLayer` or a video-call view. YouTube's player is a `WKWebView`. No public API connects the two, and YouTube's policies forbid modifying the player or extracting the stream. |
| **B** YouTube → TaskLens Web Player | **SUPPORTED on a real iPhone** | Device log (iPhone, iOS 26.6.2, 2026-10-04): load → `ready`, `playVideo()` → `playing`, then `paused` at 6.9 s, `playing` again at 7.2 s, `paused` at 13.8 s, `stopVideo()` → `ready`. No error. The CI simulator's error 150 was specific to the simulator or CI network. |
| **C** YouTube → YouTube app → YouTube/iOS PiP | **SUPPORTED (by YouTube)** | Device log: Open in YouTube → `openURL accepted true`, TaskLens went to the background (twice). YouTube Help: PiP is on iOS 15+ for all content except music (Premium-only). TaskLens cannot see or control YouTube's own PiP, so that part is YouTube's. |
| **D** TaskLens Native Media → Native PiP | **SUPPORTED on a real iPhone** | Device log: `isPictureInPictureSupported = true`, `isPictureInPicturePossible = true`, `startPictureInPicture` → `willStart`/`didStart`/`active = true` for both the generated video and Apple's HLS sample; pause, play and seek during PiP; `stopPictureInPicture` and the PiP restore button → `restoreUserInterface`/`didStop`. |

**Decision: CASE B (confirmed on device, 2026-10-04).** YouTube plays inside TaskLens with the official player, so "Play in TaskLens" stays alongside "Open in YouTube". There is still no TaskLens PiP for YouTube (path A is not supported), and no code change is needed.

---

## 1. Technical Findings (project audit)

| Item | Value |
|---|---|
| iOS deployment target | 17.0 |
| Xcode (CI) | 26.6 (17F113) on macos-26 |
| Swift | 6.3.3 (language mode 6) |
| SDK / simulator | iOS 26.5, iPhone 11 |
| Device target | iPhone only (`TARGETED_DEVICE_FAMILY: 1`) |
| Existing PiP | `PiPFeature/PictureInPictureEngine.swift`: AVKit + `AVSampleBufferDisplayLayer` (cards drawn as video frames) |
| Existing YouTube handling | None (before this phase, a plain link) |
| Share Extension | `App/TaskLensShare/ShareViewController.swift` + `ShareFeature` + `ShareIntake`/`ShareOutbox` |
| Link Intelligence | `Engine/Detectors.swift` (`URLDetector`), `ContextEngine.swift`, `Normalizer.swift` |
| Media Player | None (before this phase) |
| WebView | `BrowserFeature/WebViewStore.swift` (WKWebView with `allowsInlineMediaPlayback`) |
| AVFoundation / AVKit | PiP engine only (`PictureInPictureEngine.swift`) + audio session |

Responsible files: Share → `ShareViewController` / `ShareView`. URL classification → `ContentClassifier` + `URLDetector`. YouTube detection → `Media/YouTubeLink.swift` (new). Media → `TLMediaUI` (new). PiP → `PiPFeature` + `NativeVideoPiP` (lab). Action Engine → `ActionEngine.swift`. Session → `CaptureService` / `SessionContentService`.

The architecture was not rewritten. Additions: one new module (`TLMediaUI`), one new action (`playVideo`) and metadata on the existing link entity.

## 2. Official API Findings

| Question | Answer | Source |
|---|---|---|
| 1. Can TaskLens play YouTube in-app through an official mechanism? | **Yes**: the YouTube IFrame Player API in a WebView (the method YouTube recommends for iOS via `youtube-ios-player-helper`) | developers.google.com/youtube/iframe_api_reference, /v3/guides/ios_youtube_helper |
| 2. Can that player be a source for AVPictureInPictureController? | **No** | Apple: ContentSource accepts only `AVPlayerLayer`, `AVSampleBufferDisplayLayer` or `activeVideoCallSourceView` |
| 3. Can the WebView/iframe become AVPlayerLayer or AVSampleBufferDisplayLayer? | **No** | No public API exposes the `<video>` inside the WebView as an AVPlayer |
| 4. The technical reason | The video plays inside WebKit (in a cross-origin iframe from youtube.com). The app can only reach it through the YouTube player API (play/pause/seek), not the frames or the stream. Capturing frames or extracting the stream is forbidden. | YouTube Developer Policies III.I.6/7/14, III.E.1.a |
| 5. Is there an official API that turns embedded playback into native PiP? | **No** for TaskLens's own PiP. WebKit has `allowsPictureInPictureMediaPlayback` (public, default true) for HTML5 video, but TaskLens can't start or observe that PiP. YouTube also forbids playback from a player that isn't visible (III.I.9), so TaskLens pauses the player when it goes to the background. | developer.apple.com WKWebViewConfiguration; YouTube Policies III.I.9 |
| 6. YouTube App PiP vs TaskLens PiP? | **Different.** YouTube app PiP is a YouTube feature (non-Premium except music, iOS 15+) controlled by YouTube. TaskLens PiP only shows TaskLens content (cards, or media we own). | support.google.com/youtube/answer/7552722 |

YouTube requirements implemented: player at least 200×200 (16:9, full width), nothing drawn over the player, no autoplay (playback starts only from the user's tap), app identity sent as Referer through `loadHTMLString(baseURL: https://<bundle id>)`, and only documented `playerVars` (`playsinline`, `rel`, `origin`, `start`).

## 3. Architecture Tested

- **Option A (YouTube URL → AVPlayer):** NOT SUPPORTED. AVPlayer needs a media file or stream URL, and a watch page is neither. Getting a stream URL means extraction, which is forbidden (III.I.14). Not attempted, per Part 12.
- **Option B (IFrame → WKWebView):** built as `YouTubePlayerService` (load/play/pause/seek/stop; ready/playing/paused/buffering/ended/error states). It loads on CI; playback was refused with 150. The connection to native PiP is NOT SUPPORTED (Part 8).
- **Option C (YouTube app):** the "Open in YouTube" action (`https://www.youtube.com/watch?v=…`, a universal link).
- **Option D (native media):** `NativeVideoPiP`: AVPlayer + AVPlayerLayer + AVPictureInPictureController, with the full delegate (willStart/didStart/failedToStart/willStop/didStop/restoreUI) and KVO on `isPictureInPicturePossible`/`isPictureInPictureActive`. Sources: a 20-second test video written on the device (AVAssetWriter, offline), or Apple's official HLS sample.

## 4. Real Device Results

**Done on 2026-10-04** on the user's iPhone (iOS 26.6.2), lab build installed with Sideloadly; results in sections 5 to 7 and the test matrix. Setup used:
- `codemagic.yaml`: builds an unsigned Debug IPA (`TaskLens-DeviceLab.ipa`).
- `docs/device-testing.md`: installation with Sideloadly on Windows using a free Apple ID.
- **Video PiP Lab** (Settings › Developer, Debug only): every Part 10 test, a checklist and a **Copy Log** button.

Rows not covered by the log (seek in YouTube, lock screen, background while YouTube plays) stay open.

## 5. YouTube Result

- On the simulator: load ✓ (`ready`), play ✗ (`error 150`).
- **On the iPhone:** load ✓, play ✓ (`playing` at 0.2 s), pause ✓ (6.9 s), play again ✓, pause ✓ (13.8 s), stop ✓. So error 150 came from the simulator or CI network, not from YouTube refusing TaskLens.
- Not covered by the log: seek, and going to the background *while* YouTube plays (the one background event shows the player already stopped, state `ready`).

## 6. Native PiP Result

- YouTube → TaskLens PiP: NOT SUPPORTED (see above).
- TaskLens native media → PiP: **works on the iPhone.** Generated video: start → active, pause/play/seek while in PiP, PiP restore button → `restoreUserInterface` → stop. Apple HLS sample: possible becomes true once playing, start → active, seek, stop. The simulator still reports unsupported, so CI can't cover it.

## 7. External YouTube Result

On the iPhone, Open in YouTube was accepted by iOS (`openURL accepted true`) and TaskLens went to the background as YouTube opened, twice. Whether YouTube then showed its own PiP is not visible to TaskLens and is not claimed.

## 8. What Works (verified)

- Offline detection of `youtube.com/watch`, `m.youtube.com`, `youtu.be`, `shorts`, `live`, `embed`, `youtube-nocookie`, `music.youtube`, plus the `t=`/`start=` start time.
- Rejection of invalid links (12-character ID, channel, playlist, search, a fake domain, a different scheme).
- Lens / Share / Clipboard / Session show **"YouTube Video"** + **Video ID**.
- Actions: **Open in YouTube**, **Play in TaskLens**, **Save** (primary); Search, Share, Copy, Note (secondary). **No PiP action.**
- Session save keeps `platform=youtube`, `contentType=video`, `videoID`, the URL, `sessionID` and `createdAt`. Restore returns them. Search finds the item by the video ID.
- YouTube's player loads inside TaskLens with the app identity (Referer).

## 9. What Does Not Work / Not proven

- Native TaskLens PiP for YouTube: not possible through a public API.
- YouTube playback inside TaskLens: works on the iPhone; refused only on the CI simulator (150).
- Native media PiP: works on the iPhone; not testable on the simulator.
- Saving the playback position (Part 15): **not implemented**, because the player isn't native (Path B). We don't claim to restore YouTube's playback state.

## 10. Recommended Supported Architecture

1. **Keep:** YouTube detection, metadata, Save/Session/Search/Note, and **Open in YouTube** (the official path to PiP through YouTube's app).
2. **Play in TaskLens:** keep it. The iPhone test showed playback works (CASE B).
3. **Don't build:** a fake PiP, frame capture, stream extraction, or background playback.
4. **TaskLens PiP** stays for TaskLens's own content (cards), and for media we have the right to play (Path D) once the device confirms it.

## 11. Files Changed

New:
- `Packages/TaskLensKit/Sources/TLCoreServices/Media/YouTubeLink.swift`
- `Packages/TaskLensUI/Sources/TLMediaUI/YouTubePlayerService.swift`
- `Packages/TaskLensUI/Sources/TLMediaUI/YouTubePlayerScreen.swift`
- `Packages/TaskLensUI/Sources/TLMediaUI/NativeVideoPiP.swift`
- `Packages/TaskLensUI/Sources/TLMediaUI/VideoPiPLabView.swift` (Debug only)
- `Packages/TaskLensKit/Tests/TLCoreServicesTests/YouTubeLinkTests.swift`
- `Packages/TaskLensUI/Tests/TaskLensUITests/MediaTests.swift`
- `App/TaskLensAppUITests/VideoPiPUITests.swift`
- `codemagic.yaml`
- `docs/device-testing.md`
- `scripts/device-lab.sh`

Modified:
- `ActionEngine.swift`, `ContextEngine.swift`, `Detectors.swift`, `Action.swift`
- `ActionCard.swift`, `ActionPlan.swift`, `AnalysisViews.swift`
- `LensView`, `ShareView`, `ClipboardView`, `SessionDetailView` (YouTube type row)
- `SettingsView` (Developer section, Debug only)
- `Package.swift` (the `TLMediaUI` module)
- `scripts/strings.py` (+19 Arabic/English keys, 603 in total)
- `scripts/ci.sh` (`VIDEO` lines in the summary)

## 12. Tests Passed

- TaskLensKit + TaskLensUI unit tests (run 40: all passed). In run 42, TaskLensUI showed 125 tests / 27 suites passing, including 8 new ones. The App target's 15 tests passed.
- New TaskLensKit tests: the parser (11 valid link forms, 15 invalid forms, start time, canonical link, text input), the engine (metadata with no network, actions, no PiP, Share Sheet), and the session (save + restore + search).
- UI (simulator): `testYouTubeLinkIsDetectedWithItsActions` ✓. In total, 54 UI tests passed.
- Release archive for devices (unsigned): ✓ (run 40).

## 13. Tests Failed / Skipped

- `testPlayInTaskLensUsesYouTubesPlayer`: **skipped with an explicit reason.** YouTube refused playback with `error.embeddingNotAllowed.150`. In run 41 it was a failure; it is now a skip with the reason printed in the summary.
- `testNativeMediaPictureInPicture`: **skipped.** `supported=false` on the simulator.
- Correction: in run 41 this test reported "not supported" based on an empty reading (the status row wasn't on screen). The test was fixed, and run 42 proved `supported=false` with real values.
- `HardeningUITests` (×2): the known, older Dynamic Type audit failure in the Screen Lens section. Not related to this phase.
- `testRealShareExtensionFromSafari`: skipped (as before).

## Test Matrix (Part 18)

| # | Test | Expected | Actual | Status |
|---|---|---|---|---|
| 1 | youtu.be detection | videoID | dQw4w9WgXcQ | PASS |
| 2 | youtube.com/watch detection | videoID (+ m., music., extra params) | correct | PASS |
| 3 | shorts detection | kind=short | short | PASS |
| 4 | invalid URL | nil | nil for 15 forms | PASS |
| 5 | YouTube player (load) | ready | ready (simulator and iPhone) | PASS |
| 6 | play | playing | iPhone: playing at 0.2 s (simulator: error 150) | PASS (device) |
| 7 | pause | paused | iPhone: paused at 6.9 s and 13.8 s, resumed between | PASS (device) |
| 8 | seek | time advances | not in the device log | NOT TESTED |
| 9 | native PiP (YouTube) | — | no API | NOT SUPPORTED |
| 9b | native PiP (own media) | active=true | iPhone: didStart, active=true (generated video and Apple HLS) | PASS (device) |
| 10 | PiP restore | restoreUI + return | iPhone: restoreUserInterface → didStop | PASS (device) |
| 11 | background | YouTube pauses | iPhone: backgrounded only after stop (state ready); not tested while playing | NOT TESTED |
| 12 | lock screen | — | not in the device log | NOT TESTED |
| 13 | external YouTube | opens the YouTube app | iPhone: openURL accepted, app went to background | PASS (device) |
| 14 | offline detection | detection with no network | pure parser, no network | PASS |
| 15 | Session save | metadata saved | platform/contentType/videoID | PASS |
| 16 | Session restore | same item + metadata | correct, and search finds it | PASS |

## 14. Known Limitations

- No real-device result yet (everything in sections 4–7 depends on the log).
- The simulator doesn't support AVKit PiP, so Path D can't be proven in CI.
- YouTube may refuse playback in some environments (150). The app shows a clear message and the **Open in YouTube** button.
- The YouTube player needs internet. Detection, save, search and notes work without it.
- The lab is English-only and exists only in Debug builds; it isn't in the release build.
- The free Apple ID on Sideloadly: valid for 7 days. Signing the extensions may need them removed, in which case sharing from YouTube can't be tested.
- Playback position isn't saved (the player isn't native).

## Performance (Part 19)

**Not measured.** It needs a device. Design choices that reduce cost:
- The YouTube WebView uses a non-persistent data store and is unloaded when the screen closes.
- Playback stops when the app goes to the background.
- The lab's test video is written once to a temporary file.

## App Store implications

- **Path B:** must follow YouTube's API terms: no overlays, no background playback, at least 200×200, and the app identity sent. We follow these. Adding "Play in TaskLens" doesn't change the privacy labels (the player only loads when the user taps), but YouTube collects its own data inside the player. That should be mentioned in the privacy policy.
- **Path D / the existing PiP:** the "audio" background mode is still a risk under guideline 2.5.4 (already recorded). It must not be used for YouTube.
- **The lab:** `#if DEBUG`, so it doesn't reach the store.
