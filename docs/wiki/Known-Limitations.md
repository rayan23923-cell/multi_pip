# Known Limitations

## Release blockers (Phase 18 verdict: not production-ready)
1. No app icon.
2. Placeholder identifiers (`com.example.tasklens`) and no signing.
3. Not tested on a real iPhone for camera, Safari sharing, widgets, Live Activities, PiP and launch time.
4. Decision needed on the PiP `audio` background mode (App Review guideline 2.5.4).
5. Accessibility: two audit tests fail on Dynamic Type in the Screen Lens section (cause not found yet); some dark-mode contrast is weak.

## App Store risks
| Risk | Level |
|---|---|
| Upload blockers above | Blocker |
| PiP with `audio` background mode | High |
| Visible "Later" buttons (unfinished actions) | Medium |
| In-app browser raises the age rating | Medium |
| Screen Lens untested on iOS 27 | Medium |
| AI through the user's server | Low–medium (disclosure and consent exist) |

Details: [Phase 17 report](Report-phase17-app-store-compliance).

## Platform limits
- **PiP** shows only video layers. TaskLens draws cards as video frames; arbitrary content over other apps is not possible.
- **YouTube** cannot go into TaskLens's PiP. It plays inside TaskLens with the official player, or in the YouTube app with YouTube's own PiP.
- **Screen Lens** needs iOS 27; CI has no iOS 27 SDK, so that code is not compiled there.
- **Clipboard** cannot be watched in the background; reading another app's text needs the user's paste.
- **iPhone 11** has no Dynamic Island and no Apple Intelligence.
- **PowerPoint decks with speaker notes** cannot be rendered by iOS; TaskLens suggests a PDF export.

## Open issues
- A local-format phone number inside a sentence is not offered "Call".
- QR codes do not read in the simulator.
- PDF text extraction inside the share sheet is still "Later".
- "Later" actions: reminder, summarize, contact, ask AI.
- Flaky UI tests: PDF reader page (fix on the unmerged branch `claude/fix-pdf-reader-page`) and the share sheet test.
- Auto-play tests need up to 180 s on a busy CI simulator.
