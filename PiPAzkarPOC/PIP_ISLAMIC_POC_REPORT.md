# PIP_ISLAMIC_POC_REPORT

Status: **code complete, device testing pending.**
Date: 2026-10-08

> Rule followed: nothing in this report is marked PASS unless it was observed on a real device.
> The POC was written in a Linux cloud environment with no Xcode, Simulator or iPhone, so it has
> **not been compiled or run yet**. Every on-device result below is UNTESTED until the checklist in
> section 6 is run and the results are pasted back.

---

## 0. Short verdict (provisional)

**VERDICT: CONDITIONAL GO (provisional, based on Apple documentation only)**

| Item | Result | Basis |
|---|---|---|
| Automatic PiP | UNTESTED | API exists and is documented (iOS 14.2+) |
| Arabic text | UNTESTED | Rendered to video frames with Core Text; no doc-level blocker |
| Dynamic update | UNTESTED | Sample-buffer source accepts new frames at any time; background execution during PiP is the open question |
| Background persistence | UNTESTED | PiP is designed to float over other apps; not yet observed |
| Audio | UNTESTED | Audio session + background mode are required by docs; whether an audible track is needed is UNKNOWN |
| Controls | **Expected FAIL for custom Next/Previous**, Play/Pause supported by API | Docs: no custom PiP buttons exist; only play/pause, skip ±interval, close, return-to-app |

Why "conditional": the core path is officially supported by AVKit, but (a) it depends on the app being
in a "playing" state when it goes to the background, (b) App Review may treat a text-only "video" as
using PiP outside its intended purpose, and (c) the control set is fixed by the system.

---

## 1. Executive summary

iOS PiP cannot host a SwiftUI view or a UIView. It can only present one of three content sources
(Apple docs, `AVPictureInPictureController.ContentSource`):

1. `AVPlayerLayer` (an `AVPlayer` playing a media item),
2. `AVSampleBufferDisplayLayer` with an `AVPictureInPictureSampleBufferPlaybackDelegate` (iOS 15+),
3. an active video call (`AVPictureInPictureVideoCallViewController`), intended for video-calling apps.

The POC uses option 2: the app draws the Arabic dhikr into a 1280×720 pixel buffer with Core Text
(RTL paragraph, large bold system font, harakat preserved), wraps it in a `CMSampleBuffer`, and enqueues
it on an `AVSampleBufferDisplayLayer` that sits inline on the main screen. A PiP controller built on that
layer has `canStartPictureInPictureAutomaticallyFromInline = true`. The text rotates every 5 seconds by
enqueueing a new frame; a footer clock is redrawn twice a second so a tester can see whether frames keep
arriving while PiP floats over Safari or Notes.

Nothing in Apple's documentation forbids this scenario. Whether it actually behaves as hoped on device
(auto start on swipe-home, continued updates in the background, no audio required) has to be proven by
the device test.

---

## 2. What Apple officially supports (Phase 1 research)

Sources: Apple Developer Documentation pages for `AVPictureInPictureController`,
`AVPictureInPictureController.ContentSource`, `AVPictureInPictureSampleBufferPlaybackDelegate`,
`canStartPictureInPictureAutomaticallyFromInline`, `requiresLinearPlayback`,
`AVPictureInPictureVideoCallViewController`, "Adopting Picture in Picture in a Custom Player",
and App Store Review Guidelines 2.5.1 / 2.5.4 (fetched 2026-10-08).

| # | Question | Answer | Confidence |
|---|---|---|---|
| 1 | Content types PiP can use | `AVPlayerLayer`, `AVSampleBufferDisplayLayer` (iOS 15+), active video-call view controller. Docs: "The system supports displaying content from an AVPlayerLayer or AVSampleBufferDisplayLayer in a Picture in Picture window." | Documented |
| 2 | AVPlayer/AVPlayerLayer or AVSampleBufferDisplayLayer with locally generated visuals? | Yes. `AVSampleBufferDisplayLayer` displays any `CMSampleBuffer` you create, including uncompressed BGRA frames you draw yourself. `AVPlayer` could also play a locally generated video file (e.g. written with `AVAssetWriter`), but that is static and harder to update. | Documented |
| 3 | Large Arabic text rendered locally and shown in PiP? | Technically yes: text is drawn into the frame before it becomes video, so PiP just sees pixels. No network needed. Legibility at small PiP sizes is UNKNOWN until tested. | Inferred from (2) |
| 4 | Update content during PiP? | The sample-buffer layer accepts new frames at any time, and Apple provides `invalidatePlaybackState()` for state changes. Whether the app keeps executing timers while backgrounded with PiP active is **UNKNOWN** (expected yes, because the app is a media-playback app with the `audio` background mode and an active PiP session). | Partly documented, partly UNKNOWN |
| 5 | Automatic PiP on background via `canStartPictureInPictureAutomaticallyFromInline = true`? | Documented (iOS/iPadOS 14.2+): "PiP starts automatically when the controller embeds its content inline and the app transitions to the background. Only set this value to true for content that you intend to be the user's primary focus." | Documented |
| 6 | iOS conditions | Device must return `isPictureInPictureSupported() == true`; `isPictureInPicturePossible` must be true (layer in a window and on screen, nothing else blocking such as an active FaceTime PiP); audio session configured for playback; controller strongly retained; for sample-buffer sources the delegate must report "not paused" for auto-start. The user can also disable auto-start in Settings > General > Picture in Picture. | Mostly documented; the "must be playing" condition for sample buffers is inferred |
| 7 | Background Modes | `UIBackgroundModes = audio` ("Audio, AirPlay, and Picture in Picture"). The AVPictureInPictureController page states PiP requires configuring the app for background audio playback. | Documented |
| 8 | Audio constraints | Audio session category must be `.playback` (mode `.moviePlayback` recommended). Without `.mixWithOthers`, activating the session interrupts other audio (music, podcasts). Whether an **audible track** is required for PiP to start or stay alive is UNKNOWN; the POC tests both. | Category documented; audible-track requirement UNKNOWN |
| 9 | AVPlayerViewController vs AVPictureInPictureController vs AVSampleBufferDisplayLayer | `AVPlayerViewController`: full standard player UI, PiP built in, also has `canStartPictureInPictureAutomaticallyFromInline`, but needs an `AVPlayer` item (a real video). `AVPictureInPictureController`: the PiP engine for custom players; works with either an `AVPlayerLayer` or a sample-buffer layer. `AVSampleBufferDisplayLayer`: not a controller, just the rendering layer that lets you push frames you generate yourself; it is the piece that makes live-drawn text possible. | Documented |
| 10 | App Store compliant? | Public APIs only, so 2.5.1 is satisfied. Risk is 2.5.4 ("background services for their intended purposes") and 2.5.1 ("use APIs for their intended purposes"): PiP is documented as a video feature. A text-only stream with a silent audio session could be read as misuse. **UNKNOWN**; see section 12. | Guideline text documented; outcome UNKNOWN |

---

## 3. What was implemented

Project: `pip-poc/IslamicPiPPOC/` (open `IslamicPiPPOC.xcodeproj` in Xcode 16+; iOS 16+ deployment target).

| File | Role |
|---|---|
| `IslamicPiPPOC/IslamicPiPPOCApp.swift` | App entry, logs scene phase changes |
| `IslamicPiPPOC/ContentView.swift` | Required screen: title "Islamic PiP Technical Test", Arabic text, Prepare PiP / Start PiP / Stop, status rows (Supported, Possible, Active, Playing), toggles, on-screen log and "Copy results" |
| `IslamicPiPPOC/PiPEngine.swift` | Audio session, `AVPictureInPictureController(contentSource:)` with a sample-buffer source, `canStartPictureInPictureAutomaticallyFromInline = true`, KVO, delegates, 5 s rotation, frame pump, optional audio |
| `IslamicPiPPOC/AzkarFrameRenderer.swift` | Draws Arabic text into a BGRA `CVPixelBuffer` and wraps it in a `CMSampleBuffer` flagged DisplayImmediately |
| `Info.plist` | `UIBackgroundModes = [audio]` (merged with the generated plist) |
| `project.yml` | Fallback XcodeGen spec if the hand-written project file does not open |

Behaviour:

- **Prepare PiP**: activates `AVAudioSession` (`.playback`, `.moviePlayback`), creates the controller, enables auto-start, marks playback as playing, starts the 5 s text rotation and a 0.5 s frame pump.
- **Start PiP**: calls `startPictureInPicture()` manually (fallback test).
- **Text sequence** (every 5 s): سُبْحَانَ اللَّهِ وَبِحَمْدِهِ → الْحَمْدُ لِلَّهِ → اللَّهُ أَكْبَرُ → لَا إِلَهَ إِلَّا اللَّهُ.
- **Footer** in every frame: `n/4 · HH:mm:ss`, so a frozen clock in PiP means the app stopped producing frames.
- **Audio toggle**: plays a locally generated 5 s two-note chime (synthesized in code, no copyrighted content). Off = text only.
- **Controls picker**: *Live* returns an infinite time range (system should show play/pause only); *Steppable* returns a finite range so the system shows skip buttons, which the POC maps to previous/next.
- **Copy results**: copies device model, iOS version, all flags and the full log to the clipboard for pasting back.

Not used: private APIs, WebView, simulated Home press, accessibility tricks, network, Firebase, backend, login, database, notifications, Live Activities, widgets.

---

## 4. What failed

Nothing has been run yet, so nothing has failed on device. Known doc-level limitations:

- Custom **Next / Previous** buttons cannot be added to the PiP window. AVKit exposes no API for custom PiP buttons.
- PiP cannot host SwiftUI/UIView content directly; all content must be video frames.

## 5. Exact reason for each failure

| Limitation | Reason |
|---|---|
| No custom Next/Previous | The PiP control set is drawn by the system. The sample-buffer delegate only receives `setPlaying(_:)` and `skipByInterval(_:)`. Skip buttons show the system's ±interval icons, not "next/previous" icons, so mapping them to dhikr navigation works functionally but is visually misleading. |
| No direct SwiftUI in PiP | `ContentSource` only accepts a player layer, a sample-buffer display layer, or a video-call source. |

---

## 6. Device / iOS test results

**Not run yet.** Fill in from the "Copy results" output.

| Field | Result |
|---|---|
| Device model | UNTESTED |
| iOS version | UNTESTED |
| PiP supported | UNTESTED |
| PiP possible | UNTESTED |
| Automatic PiP works | UNTESTED |
| Text rendering works | UNTESTED |
| Arabic RTL works | UNTESTED |
| Content updates work | UNTESTED |
| Audio works | UNTESTED |
| PiP survives app backgrounding | UNTESTED |
| PiP survives switching to another app | UNTESTED |

### Device test checklist

Setup (Mac with Xcode 16 or later, iPhone on iOS 16 or later, USB or Wi-Fi debugging):

1. Open `IslamicPiPPOC/IslamicPiPPOC.xcodeproj`. Under Signing & Capabilities pick your Team; change the bundle id if Xcode complains. Confirm "Background Modes → Audio, AirPlay, and Picture in Picture" is ticked (it comes from `Info.plist`).
2. On the iPhone: Settings > General > Picture in Picture > **Start PiP Automatically = ON**.
3. Run on the iPhone (not the Simulator).

Tests (note PASS/FAIL for each):

- **T1 Supported / Possible**: after launch, "PiP Supported" = YES. Tap **Prepare PiP**; "PiP Possible" should turn YES and the preview should show the Arabic text.
- **T2 Automatic PiP, text only**: Audio OFF. Prepare PiP, then swipe up to Home. Does a PiP window appear by itself? Check the log after returning for `PiP willStart (appState=...)`.
- **T3 Arabic text**: In PiP, is the text right-to-left, correctly joined, harakat visible, readable at the smallest and largest PiP sizes (pinch to resize)?
- **T4 Dynamic update**: Does the text change every 5 s inside PiP, and does the footer clock keep ticking?
- **T5 Over other apps**: With PiP running open Safari, Notes and one more app. Does PiP stay visible, keep updating, and not bounce back to the app? Also try stashing PiP to the screen edge and bringing it back.
- **T6 Audio**: Repeat T2 to T5 with Audio ON. Note any difference (for example, PiP only auto-starts or only keeps updating with audio on). Also note whether music from another app is interrupted.
- **T7 Controls**: In PiP, tap once to reveal controls. With picker on *Steppable*: are there play/pause and skip buttons? Does skip forward/back change the dhikr? Does pause stop the rotation (footer shows "paused")? With *Live*: are skip buttons hidden?
- **T8 Manual start (fallback)**: Toggle auto-start off, tap **Start PiP**. Does PiP open?
- **T9 Edge cases**: Lock the phone while PiP is on, then unlock. Open the app switcher instead of Home. Leave PiP running 10+ minutes. Note what happens.

After testing, tap **Copy results** and paste the text (plus your PASS/FAIL notes) back into the thread so this report can be finalized.

---

## 7. Automatic PiP result

UNTESTED. Implementation: `controller.canStartPictureInPictureAutomaticallyFromInline = true`, layer inline and visible, delegate reports playing. Expected per docs: PiP starts when the user swipes to Home. UNKNOWN whether iOS requires an audible track, or treats sample-buffer content that never "advances" as eligible.

## 8. Arabic text result

UNTESTED. Rendering uses `NSAttributedString` with `baseWritingDirection = .rightToLeft`, center alignment, 110 pt bold system font (SF Arabic fallback) on a 1280×720 frame. No network or bundled font required.

## 9. Dynamic content update result

UNTESTED. Each change is a new `CMSampleBuffer` enqueued with `DisplayImmediately`. The footer clock is the evidence. UNKNOWN: whether timers keep firing while the app is backgrounded with PiP active (log line `willEnterForeground, frames enqueued while in background: N` will show this).

## 10. Audio result

UNTESTED. Audio session and background mode are required by Apple. Whether audible audio is required: UNKNOWN; T2 vs T6 answers it.

## 11. PiP control result

Per docs: available = play/pause, skip back/forward (sample-buffer delegate), close, return to app. Not available = custom Next/Previous buttons or custom icons. `requiresLinearPlayback = true` hides skip and seek. On-device behaviour UNTESTED.

**Result: Play/Pause expected supported; true Next/Previous = FAIL by design** (can only be approximated with skip buttons).

## 12. App Store compliance considerations

- **2.5.1 public APIs**: satisfied; only AVKit/AVFoundation/CoreMedia/UIKit/SwiftUI.
- **2.5.1 intended purpose / 2.5.4 background services**: the main risk. PiP and the `audio` background mode exist for media playback. A reviewer may reject an app whose PiP shows static text and whose audio session plays nothing. Mitigations: make the PiP content genuinely playable media (for example dhikr with real recited audio the app has rights to, or a proper "dhikr player" with play/pause semantics), describe it in the app description, and never use a silent audio loop to keep the app alive.
- **Auto-start guidance**: Apple says to enable `canStartPictureInPictureAutomaticallyFromInline` only when the content is the user's primary focus. Auto-start should only be on while the user is actively "playing" an azkar session, not whenever the app is open.
- Outcome of review: **UNKNOWN**. No App Review test was done.

## 13. Technical limitations

- PiP only shows video frames; no interactive UI, no scrolling, no text selection, no taps except the system controls.
- Controls are fixed by the system.
- Window size and position are controlled by the user and the system; small sizes may make long duas unreadable.
- PiP can be blocked by other PiP sessions (FaceTime, another video app) and by user settings.
- Activating a `.playback` session without `.mixWithOthers` stops the user's music.
- iPhone PiP requires iOS 14+; sample-buffer content source requires iOS 15+.
- Background execution while PiP is active is UNKNOWN until T4/T5.

## 14. Recommended architecture for the real product (if device tests pass)

- **Rendering**: keep `AVSampleBufferDisplayLayer` + Core Text frames; render on a background queue, cache one frame per dhikr, and only redraw on change (not on a fixed pump) to save battery.
- **Playback model**: model a session as a real "player" (play/pause, current item, progress) so PiP semantics are honest; drive state through `invalidatePlaybackState()`.
- **Audio**: prefer real, rights-cleared recited audio per dhikr, played in sync with the text. This makes PiP use clearly media playback for App Review.
- **Navigation**: steppable time range with skip mapped to next/previous; accept the system icons or use in-app navigation instead.
- **Auto-start**: enable only while a session is playing; disable when paused or finished.
- **Fallbacks**: Live Activities / widgets / notifications for users or devices where PiP is unavailable (out of scope for this POC).

## 15. Go / No-Go decision

**Provisional: CONDITIONAL GO.**

Apple documents every piece of the core scenario (sample-buffer content source, automatic start from inline, background audio mode), so iOS does not prohibit it on paper. The conditions are: device tests T2 to T5 must pass, custom Next/Previous is not available, and App Review acceptance of text-centric PiP is uncertain. If T2 (automatic start) or T4/T5 (updates over other apps) fail on device, the verdict changes to **NO-GO** for the core scenario.
