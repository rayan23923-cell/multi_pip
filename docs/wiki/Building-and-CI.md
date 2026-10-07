# Building and CI

## Requirements
- Xcode 26 or newer (Swift 6 language mode)
- iOS 17.0 deployment target; reference device: iPhone 11
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build locally

```sh
xcodegen generate        # creates TaskLens.xcodeproj (not committed)
open TaskLens.xcodeproj
scripts/ci.sh            # every build and test suite on an iPhone 11 simulator, as CI does
```

Before a device build, replace `com.example.tasklens` and `group.com.example.tasklens` in `project.yml`
with your own bundle ID and App Group, and set your development team.

## Localization
UI strings come from `scripts/strings.py` (English and Arabic). Edit it and run
`python3 scripts/strings.py`; tests fail if a key is missing in either language.

## GitHub Actions
All workflows start by hand from the Actions tab (the repository is public, so minutes are free).

| Workflow | What it does |
|---|---|
| **CI** | Build app and extensions, unit tests, XCUITests (input `ui_tests`, default on), then an unsigned Release archive. A full run takes about an hour. If any UI test fails the archive step does not run, so check the archive with `ui_tests=false`. |
| **Screenshots** | Captures the main screens into `docs/screenshots` and commits them. |
| **PPTX audit probe** | Runs the A8 PowerPoint probe. |
| **Publish wiki** | Publishes `docs/wiki` and `docs/reports` to this wiki. Also runs when those folders change. |

A newer run on the same branch cancels the older one.

## Device builds without a Mac
`codemagic.yaml` builds an unsigned IPA for sideloading. See [Device Testing](Device-Testing).
