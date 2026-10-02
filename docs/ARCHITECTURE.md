# TaskLens architecture

## Pipeline

```
CONTENT ──► CONTEXT ──► ACTION ──► WORKSPACE ──► SESSION
(typed, pasted,   (ContextItem +     (Action /         (grouping and
 shared, captured) DetectedEntity)    ActionResult)     resume)
```

Phase 2 implements the foundation for every stage except intelligence: content is
validated and stored as `ContextItem`s inside `Session`s and `Workspace`s. Entity
detection and action suggestion are protocol boundaries (`EntityDetecting`,
`ActionSuggesting`, `ActionPerforming`) with no-op defaults.

## Modules

```
TaskLensKit (no UI frameworks; builds for iOS and macOS)
  TLFoundation    JSONValue, Identifier<T>, DateProviding, TaskLensError, TLLogger
  TLDomain        Models, Repository protocol, engine contracts
  TLData          InMemoryRepository, JSONFileRepository, StoreLocation, Repositories
  TLCoreServices  WorkspaceService, SessionService, CaptureService, NoteService, ClipboardService

TaskLensUI (SwiftUI, iOS)
  TLLocalization  String catalog (en, ar), L10nKey, L10n, error messages
  TLDesignSystem  Spacing/radius tokens, cards, badges, empty states, shared rows
  TLNavigation    AppTab, AppRoute, AppRouter
  CommandCenterFeature, WorkspacesFeature, SessionsFeature, SettingsFeature

App
  AppContainer    Composition root (the only place that picks concrete types)
  RootView        Tabs + one NavigationStack per tab + route → screen mapping
```

## Dependency rules

1. `TLDomain` depends only on `TLFoundation`.
2. `TLCoreServices` depends on `TLDomain` protocols, never on `TLData`.
3. Features depend on services and on `TLNavigation`, never on each other or on `TLData`.
4. Only the app target knows concrete repositories (`AppContainer`).
5. Extensions (Share, Widgets) will import `TaskLensKit` modules only, to stay within extension memory limits.

## Persistence

`Repository<Model>` is the single persistence abstraction. Two implementations exist:

- `InMemoryRepository` for tests, previews and the failure fallback.
- `JSONFileRepository`: one versioned JSON file per entity in the App Group container
  (falls back to Application Support when the group is unavailable). Writes are atomic
  and use `completeFileProtectionUntilFirstUserAuthentication` on iOS.

The JSON store suits early-phase data volumes. A database backend (SwiftData or SQLite)
can replace it behind the same protocol when search and volume require it.

## Extensibility

- Kinds that will grow (`SessionKind`, `ContextSource`, `EntityType`, `ActionType`,
  `WorkspaceColor`) are string-backed structs, so unknown values written by newer
  versions still decode.
- Every model carries `metadata: [String: JSONValue]` for additive fields.
- `Identifier<T>` prevents mixing IDs of different entities at compile time.

## Errors and logging

- One error type, `TaskLensError`, with no user-facing text. The UI maps
  `localizationKey` to a localized message (`L10n.message(for:)`).
- `TLLogger` writes to OSLog. Rule: log identifiers, counts and states only; never
  user content. `ContextContent.logDescription` exists for this.

## Navigation

`AppRouter` owns tab selection and one path per tab. Features push `AppRoute` values
via `NavigationLink(value:)` or `router.push`; the app maps routes to screens, which
keeps feature modules independent. Deep links and App Intents will call `router.open`.
