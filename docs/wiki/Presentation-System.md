# Presentation System (Track A)

## Layers

| Layer | Phase | What it is |
|---|---|---|
| Data model | A1 | `PresentationDocument`, slides and sources. `currentSlide` is zero-based inside, one-based on screen, and separate from a document's last-read page. |
| Engine | A2 | `PresentationEngine`: navigation and state through `PresentationLoading` sources. |
| PDF source | A3 | `PDFPresentationLoader`: one slide per PDF page. Password-protected PDFs are not supported. |
| Image source | A4 | `ImagePresentationLoader`: ordered images from Files or Photos. |
| UI | A5 | Presentation screen: ◀ / "Slide N / M" / ▶, Go to Slide, tap to hide controls. |
| Auto play | A6 | Play, Pause, Resume, Stop; 5, 10, 15, 30, 60 s or custom 1–3600 s. |
| Session | A7 | Each presentation reopens where it was left. |
| PowerPoint | A8–A9 | See below. |

## PowerPoint

**A8 decision.** Seven approaches were tested on the simulator. Quick Look has no slide API and orders
Arabic wrongly; PPTX → PDF works but is heavier. The chosen route is **PPTX → images**: iOS's own
WebKit lays out one slide per page offline, and each slide is snapshotted to a PNG. No dependency added.
The audit is in [`docs/presentation/A8-pptx-audit.md`](https://github.com/rayan23923-cell/multi_pip/blob/claude/project-thread-0s4dmt/docs/presentation/A8-pptx-audit.md).

| Sub-phase | Result |
|---|---|
| A9.1 Import | `.pptx` files are checked (ZIP structure, safety) and imported. |
| A9.2 Renderer | Offline `WKWebView` renderer; never keeps a half-painted slide. |
| A9.3 Integration | New slide source `.renderedImage(DocumentID, index)` and session source `.powerPoint(id)`. Slide PNGs live with the document and are deleted with it. |
| A9.4 Cache | `Generated/<id>/Slides` + `cache.json` (renderer version, size, mtime, SHA-256), written to a staging folder then renamed. A cached 100-slide deck opens in about 0.05 s. |
| A9.5.1 Errors | 11 failure categories (`PowerPointFailure`). |
| A9.5.2 Failure UI | A plain-language screen per category, with Try Again, Import PDF and Cancel where they make sense. |
| A9.5.3 PDF fallback | Next, waiting for approval. The Import PDF button is a placeholder until then. |

**Speaker notes.** iOS refuses to render decks that contain speaker notes (error 912). TaskLens never
reads or shows notes (a fixed decision); such decks get the "Speaker Notes aren't supported" screen,
which suggests exporting the deck as a PDF.

![Failure screens](https://raw.githubusercontent.com/rayan23923-cell/multi_pip/claude/project-thread-0s4dmt/docs/reports/presentation/A9.5.2-screens.jpg)

## Rules for this track
- No private APIs, no fake PiP or Broadcast, no screen recording when slide data is enough.
- The original document is never sent to a browser; nothing goes to the cloud when local works.
