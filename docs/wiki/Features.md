# Features

Everything runs on the device by default. The only network use is the optional AI server.

```
CONTENT ──► CONTEXT ──► ACTION ──► WORKSPACE ──► SESSION
```

## Command Center and Workspaces
- Quick capture, recent sessions and tool shortcuts on one screen.
- Five workspace types: Study, Work, Shopping, Developer, Custom. Each sets its icon, color, tools and default session type.

## Productivity tools
Notes, calculator, clipboard, in-app browser, documents and PDF viewer. Each tool's output can be saved
into the active session.

## Smart Clipboard and Share Extension
- Paste through the system paste button (no silent clipboard reading; iOS shows "Allow Paste" otherwise).
- Share links, text, images and PDFs from any app into TaskLens.

## Context Engine and Action Engine
- Pipeline: input → normalizer → 9 detectors (URL, email, phone, currency, number, date, address, JSON, code) → context → actions → ranking → action card.
- Rule-based, on the device, no AI and no network. Arabic-Indic digits are understood.
- Actions run only when you tap them; calling asks for confirmation.
- Currency conversion uses a rate you enter; TaskLens never guesses or downloads rates.

## Smart Sessions
Collect notes, links, documents, images, clipboard items, calculations, questions and code, each with its
time, and resume later. Sessions survive the app being closed.

## Action Lens and Screen Lens
- Vision OCR on images, camera, screenshots and PDFs; barcodes and QR codes.
- Screen Lens (iOS 27+): starts only from your tap through the system picker, captures one frame, never stores or uploads it. On iOS 17–26 use a screenshot through Action Lens.

## PiP Workspace
A note, document page, session or calculator shown in native Picture in Picture (drawn as video frames,
the only content iOS allows in PiP). Tapping the window returns to its source.

## Presentation
Present PDFs, image sets and PowerPoint files: slide controls, Go to Slide, auto play (5 s to 1 hour),
and each file reopens on the slide where you left it. See [Presentation System](Presentation-System).

## Smart Search
Keyword search across notes, links, documents, PDF text, OCR text and clipboard, with hints such as
"yesterday", "PDF", "links", plus on-device semantic search (`NLEmbedding`). Nothing is sent to the cloud.

## Workflows
Trigger → steps → result. Triggers: manual, shared link/image/text/PDF, price. Steps: OCR, extract,
convert currency, calculate, save, note, and optional AI summarize/translate. Workflows with AI steps
always ask before running.

## System integration
App Intents and Shortcuts (English and Arabic), `tasklens://` links, Home Screen widgets in three sizes,
Live Activities on the Lock Screen and Dynamic Island.

## Optional AI
Apple Intelligence where the device supports it, or your own HTTPS server (off by default, key in the
Keychain, shown before anything is sent, text only). History can be turned off and deleted.

## Languages and appearance
English and Arabic with full right-to-left layout; light and dark mode; Dynamic Type.

## Video PiP Lab (Debug builds only)
Settings > Developer. Tests YouTube's embedded player, native PiP and the YouTube app on a real device.
See [Device Testing](Device-Testing).
