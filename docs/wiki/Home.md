# TaskLens Wiki

**TaskLens** is an iPhone app for intelligent contextual multitasking: it turns what you copy, share or
capture into a suggested action, and keeps related work together in Workspaces and Sessions.
Native Swift and SwiftUI, public iOS APIs only, on-device first, English and Arabic (RTL).

**تطبيق TaskLens** لتعدد المهام الذكي حسب السياق على iPhone: يحوّل ما تنسخه أو تشاركه أو تصوّره إلى
إجراء مقترح، ويجمع العمل المرتبط في مساحات عمل وجلسات. يعمل على الجهاز أولاً، بالعربية والإنجليزية.

## Current status (2026-10-07)

- Original plan, phases 0–18: **built and tested on CI**.
- Roadmap v2, Track A (Presentation): **A9.5.2 delivered** (PowerPoint failure screen). Next: A9.5.3, PDF fallback, waiting for approval.
- Release: **not production-ready yet**. See [Known Limitations](Known-Limitations).

## Pages

| Page | Contents |
|---|---|
| [Status and Roadmap](Status-and-Roadmap) | Every phase, its commit and its status; Roadmap v2 tracks A–F |
| [Features](Features) | What the app does today, by area |
| [Architecture](Architecture) | Modules, dependency rules, persistence |
| [Presentation System](Presentation-System) | Track A: PDF, image and PowerPoint presentation |
| [Building and CI](Building-and-CI) | XcodeGen, local builds, GitHub Actions workflows |
| [Device Testing](Device-Testing) | Installing on a real iPhone without a Mac |
| [Known Limitations](Known-Limitations) | Release blockers, platform limits, open issues |
| [Reports](Reports) | The full delivery report of every phase |

## Screenshots

| | | |
|---|---|---|
| ![Command Center](https://raw.githubusercontent.com/rayan23923-cell/multi_pip/claude/project-thread-0s4dmt/docs/screenshots/01-command-center.png) | ![Lens](https://raw.githubusercontent.com/rayan23923-cell/multi_pip/claude/project-thread-0s4dmt/docs/screenshots/02-lens-phone.png) | ![Session](https://raw.githubusercontent.com/rayan23923-cell/multi_pip/claude/project-thread-0s4dmt/docs/screenshots/09-session.png) |
| ![Arabic](https://raw.githubusercontent.com/rayan23923-cell/multi_pip/claude/project-thread-0s4dmt/docs/screenshots/23-ar-command-center.png) | ![Dark](https://raw.githubusercontent.com/rayan23923-cell/multi_pip/claude/project-thread-0s4dmt/docs/screenshots/26-dark-command-center.png) | ![PiP](https://raw.githubusercontent.com/rayan23923-cell/multi_pip/claude/project-thread-0s4dmt/docs/screenshots/18-pip.png) |

All 28 screenshots are in [`docs/screenshots`](https://github.com/rayan23923-cell/multi_pip/tree/claude/project-thread-0s4dmt/docs/screenshots).

> This wiki is generated from `docs/wiki` in the repository by the **Publish wiki** workflow.
> Edit the files there, not here, or your edits will be overwritten.
