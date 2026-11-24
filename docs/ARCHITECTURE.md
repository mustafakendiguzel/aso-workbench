# Architecture

ASO Workbench is a native macOS app written in Swift 6.2 and SwiftUI, built as a Swift package with **no third-party dependencies**. About 13,500 lines in three layers that the compiler keeps apart.

```
┌──────────────────────────────────────────────────────────────┐
│ ASOWorkbench: the app (SwiftUI, SwiftData, CoreML, WebKit)   │
│   Features/  screens        Services/  jobs and state        │
│   Persistence/ data model   DesignSystem/ shared pieces      │
├──────────────────────────────────────────────────────────────┤
│ ASOProviders: talking to the outside world                   │
│   iTunes Search · autocomplete · reviews · Apple Ads ·       │
│   App Store Connect · OpenRouter · RevenueCat · HTTP client  │
├──────────────────────────────────────────────────────────────┤
│ ASOCore: pure logic, no network, no UI, fully unit-tested    │
│   models · rules · difficulty · diffs · features · versions  │
└──────────────────────────────────────────────────────────────┘
```

A lower layer never imports a higher one, so the rules and scores in `ASOCore` can be tested without a network, and a provider can be replaced without touching a screen.

## Folders

```
Sources/
├── ASOCore/
│   ├── Models/        Storefront (50 countries, Apple IDs), AppLocale, StorefrontIndexing (which languages each
│   │                  store indexes), RankOutcome, SearchResultApp, MetadataFields, Popularity, DataOrigin…
│   ├── Analysis/      DifficultyScore, CompetitionSignals, CompetitorAggregation, TitleMatch,
│   │                  RankHistory (Δ and before/after), KeywordJudgement (brand, golden, lead), IdeaGap,
│   │                  RatingTrend, KeywordImpact (value, visibility curve, gain)
│   ├── Validation/    ASORules (review + repair), MetadataValidator, MetadataDiff, TextMeasure,
│   │                  LegalFooter, ReleaseNotesDefaults
│   ├── Training/      PublicFeatures / JevFeatures → model columns, evaluation metrics
│   └── AppInfo.swift  version, repository, semantic-version comparison
├── ASOProviders/
│   ├── HTTP/          HTTPClient: host allow-list, typed errors, Retry-After, request pacing
│   ├── ITunesSearchProvider, AppStoreHintsProvider, AppReviewsProvider   (public, no key)
│   ├── AppleAds/      ES256 signer, OAuth token, Search Term Rank lists, campaign reports
│   ├── AppStoreConnect/ JWT, read/write localizations, versions, screenshot copy
│   ├── OpenRouter/    LLMClient (writer), JevClient (classification with probabilities)
│   └── RevenueCatProvider
├── CSQLite/           the platform's own SQLite as a Swift module (no package dependency)
├── ASOEngine/         platform-neutral workbench: Store (SQLite, versioned schema), Engine (add app, keywords,
│                      measure, reports), Catalog (ratings, reviews, competitors), Changes (release markers,
│                      notes, impact), Popularity (Apple Ads lists, "< N" bound), KeywordReportRow and
│                      KeywordDetail, EngineSettings (settings.json), CredentialStore and
│                      Connections (credentials.json, verify), data folder and version
├── ASOCommands/       the `aso` command line: arguments, commands, text tables and JSON (see docs/CLI.md)
├── ASOCLI/            `aso` executable, a one-line entry point into ASOCommands
└── ASOWorkbench/
    ├── ASOWorkbenchApp.swift one Window scene, Settings scene, menu commands
    ├── Persistence/         SwiftData @Model types, store location, pre-update backups
    ├── Services/            AppEnvironment (composition root) and one service per job:
    │                        tracking, research/popularity, discovery, ideas, expansion, metadata,
    │                        assistant, ads import, revenue, catalog, updates, credentials, log
    ├── DesignSystem/        SourceBadge, StatCard, DeltaLabel, ScoreBand, InlineMessage, Keycap…
    └── Features/            Root, Apps (Overview), Keywords, Research, Competitors, Metadata,
                             Reviews, Changes, Settings; Ideas and Lab (developer only)
Resources/   Info.plist, icon, models/ (bundled CoreML popularity model + report)
scripts/     bundle-app.sh (build → .app), release.sh (.dmg/.zip + GitHub release)
Tests/       ASOCoreTests, ASOProvidersTests (live Apple tests are opt-in), ASOEngineTests (store, engine, CLI)
desktop/     the Windows and Linux window (C#, Avalonia) on top of `aso`, see DESKTOP.md
```

## How data flows

```
 you ─► Keywords ▸ Update ▸ Measure
          │
          ▼
   TrackingService ──► ITunesSearchProvider (public search, paced ~3 s)
          │                 │
          ▼                 ▼
   RankObservation  (position or "not in top N", the 50 results, competition signals)
          │
          └─► ResearchService.refreshPopularity (the measured keywords only)
                 ├─ Apple Ads lists          ─► PopularityObservation(scope: country)
                 ├─ Apple Ads website index  ─► PopularityObservation(scope: index)
                 ├─ bundled model (+ Jev)    ─► PopularityObservation(scope: estimate / 6–29)
                 └─ nothing                  ─► PopularityObservation(scope: bound, "< N")
```

Everything is stored as **dated observations** that are added, never overwritten. History charts, Δ columns, before/after reports and "new since last check" all come from that one habit.

## State and concurrency

- `AppEnvironment` builds every service once and hands them to views through `@Environment`. Services are `@Observable`; views read their `progress`, `isBusy` and `lastMessage` and never call the network themselves.
- The app target compiles with `defaultIsolation(MainActor.self)`: views, services and SwiftData work on the main actor; value types that cross actors are `nonisolated` and `Sendable`; network providers are `actor`s or `Sendable` structs.
- Long jobs share one shape, `Progress { step, completed, total, isRunning }` plus `cancel()`, so every screen shows progress the same way and every job can be stopped and resumed.

## Screens and patterns

- `NavigationSplitView` with a sidebar (`List(selection:)`), one workspace per app (`.id(app)` resets state when you switch apps), an `.inspector` on the right where it helps.
- Tables use a derived `nonisolated struct Row: Identifiable, Sendable` with separate numeric sort keys; columns are split into `@TableColumnBuilder` groups (the type checker gives up beyond ~8 columns in one builder).
- Busy toolbars become a few labelled menus (Keywords: **Add · Update · Export**; Metadata: **Write · Publish · Baseline**), each menu saying what it will do.
- Every number carries a `SourceBadge`; empty states are `ContentUnavailableView`s that say what to do next.
- Keyboard shortcuts live in the menu bar (`.commands`) and reach views through notifications, so each shortcut is defined once.

## Platforms

The app is macOS only. Everything else (`ASOCore`, `ASOProviders`, `ASOEngine` and the `aso` command) has no Apple-only dependencies, so it can also be built and tested on other platforms; `ASOEngine` is where a Windows or Linux front end gets the app's jobs, on the same rules. `Package.swift` picks the package graph by build host: on macOS it is dependency-free; elsewhere the app target is left out and Apple's API-compatible [swift-crypto](https://github.com/apple/swift-crypto) stands in for CryptoKit. CI builds and tests every pull request on each platform below (`.github/workflows/`).

| Platform | Builds | Toolchain |
|---|---|---|
| macOS 15+ | everything, plus the `.app` bundle | Xcode 26 (Swift 6.2) |

Code in `ASOCore` and `ASOProviders` must stay portable: import `FoundationNetworking` next to `Foundation` when using `URLSession`, use `#if canImport(CryptoKit)` / `import Crypto` for cryptography, and avoid Apple-only frameworks.

## Adding things

- **A new data source:** a provider in `ASOProviders` with its own `HTTPClient(allowedHosts:)`, a service in `ASOWorkbench/Services`, a line in `AppEnvironment`, and an entry in [SECURITY.md](../SECURITY.md).
- **A new stored field:** give it a default value (SwiftData migrates in place); see [RELEASING.md](RELEASING.md#data-model-changes).
- **A new rule for listings:** `ASORules` in `ASOCore`, with a test.
