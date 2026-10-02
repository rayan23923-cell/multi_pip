# TaskLens

Intelligent contextual multitasking for iPhone. Native Swift and SwiftUI, public iOS APIs only.

## Requirements

- Xcode 26 or newer (Swift 6 language mode)
- iOS 17.0 deployment target; reference device: iPhone 11
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project (`brew install xcodegen`)

## Getting started

```sh
xcodegen generate        # creates TaskLens.xcodeproj (not committed)
open TaskLens.xcodeproj
```

Run every build and test suite on an iPhone 11 simulator, exactly as CI does:

```sh
scripts/ci.sh
```

## Layout

| Path | Contents |
|---|---|
| `App/TaskLens` | App shell: composition root, tabs, route mapping |
| `App/TaskLensTests` | App-level integration tests |
| `Packages/TaskLensKit` | UI-free code: foundation, domain, persistence, core services |
| `Packages/TaskLensUI` | Localization, design system, navigation, feature modules |
| `scripts/strings.py` | Source of truth for UI strings (English and Arabic) |
| `docs/ARCHITECTURE.md` | Architecture and dependency rules |

## Localization

All user-facing text comes from `Packages/TaskLensUI/Sources/TLLocalization/Resources/Localizable.xcstrings`,
generated from `scripts/strings.py`. Add strings there, then run `python3 scripts/strings.py`.
Tests fail if a key is missing in English or Arabic.

## Before a device build

Replace the placeholder identifiers `com.example.tasklens` and `group.com.example.tasklens`
in `project.yml` with your own bundle ID and App Group, and set your development team.
