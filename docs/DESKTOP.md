# Windows and Linux window

`desktop/` holds the ASO Workbench window for Windows and Linux, written in C# with [Avalonia](https://avaloniaui.net). The macOS app stays native SwiftUI; this window is for the platforms where SwiftUI does not exist.

The window computes nothing. Every rank, Δ, difficulty and verdict comes from the `aso` engine ([CLI.md](CLI.md)), which it runs with `--json` for each action. The rules therefore live in one place, `ASOCore`, and the window, the command line and the macOS app agree by construction. The window and the command line share one data file, so an app added in one shows up in the other.

## Projects

```
desktop/
├── AsoDesktop.slnx
├── global.json                 .NET SDK 10; tests on Microsoft.Testing.Platform
├── Directory.Build.props       net10.0, nullable, warnings as errors, analyzers, version from ../VERSION
├── Directory.Packages.props    every package version, pinned once
├── src/
│   ├── AsoDesktop.Core/        no UI: AsoProcessCli (runs aso), AsoClient (typed calls), the JSON contract, view models
│   └── AsoDesktop/             the Avalonia window: MainWindow.axaml, App, Program
└── tests/
    └── AsoDesktop.Core.Tests/  xUnit v3: contract, client, locator, process runner and view-model tests
        └── Fixtures/           JSON captured from the real engine
```

- **Contract.** `Contract.cs` mirrors the JSON of `aso --json`. `Fixtures/` holds real output of the engine; the contract tests parse it, so a change to the engine's JSON fails a test instead of breaking the window quietly. Refresh the fixtures from a real run of `aso … --json` when the engine's output changes on purpose.
- **Finding the engine.** In order: `ASO_CLI`, `aso` / `aso.exe` next to the window (how a package ships it), then `PATH`. Without it the window says so and what to do.
- **Arguments.** Global options go first and keywords and terms after `--`, so a keyword that starts with `-` stays a keyword. `ProcessStartInfo.ArgumentList` quotes each argument for the platform.
- **Long jobs.** `measure` streams JSON Lines progress on stderr; the window moves a progress bar per keyword and can stop the job, which ends the `aso` process.
- **View models.** CommunityToolkit.Mvvm (source-generated properties and commands). One `StatusViewModel` carries what is running and the engine's own error message.

## Build, run, test

```bash
cd desktop
dotnet build AsoDesktop.slnx
ASO_CLI=/path/to/aso dotnet run --project src/AsoDesktop      # or put aso next to the built window
dotnet test --solution AsoDesktop.slnx
```

CI (`.github/workflows/desktop.yml`) builds and tests it on Windows and Linux for every pull request. .NET telemetry is turned off there (`DOTNET_CLI_TELEMETRY_OPTOUT=1`).

## Scope

The window covers what the engine offers today:

- **Add app** (Ctrl+N): find an app by name, App Store link or ID, choose the device and the markets to track.
- **Overview:** the app's details, its Apple Ads genre, and its markets with keyword counts and last measurement; add and remove markets (removal asks first). Ratings by storefront: the latest count and average, the change since the previous check, when a new rating last arrived and the latest written review; check the tracked storefronts or every storefront.
- **Competitors:** for the selected market, the apps in the latest results of its tracked keywords (top 5, 10, 20 or 50), with the keywords each appears in and its position there.
- **Reviews:** written reviews across the app's storefronts, newest first, with new ones marked; filter by storefront, minimum rating, new only or text, and check the tracked storefronts or every storefront.
- **Keywords:** one market at a time, as in the macOS app: rank, Δ, difficulty with its tier, rating mass, title matches and brand verdicts. Filters (text, found in the results, hide brands, difficulty at most); measure the market (Ctrl+R) or only the selected keywords (Ctrl+Shift+R) with progress and Stop; copy (Ctrl+C) or remove (Delete, after a confirmation) the selection; export the macOS CSV (Ctrl+Shift+E).
- **Inspector:** for the selected keyword, the rank chart (7 days to all, rank on a reversed log scale, crosses where the app was not in the results, the best rank highlighted), difficulty with every component, competition signals, the latest top ten with your app in bold, a note, and every measurement.
- **Research:** search results, autocomplete and difficulty with every component; **Metadata:** the App Store rules check.
- **Settings:**
  - **General:** engine version and data folder (with a button that opens it).
  - **Measurement:** results per keyword, pacing, golden thresholds, writer tiers, the Δ reference, and the start-up refresh of markets not measured recently.
  - **Connections:** Apple Ads, App Store Connect, OpenRouter and RevenueCat, each with what it unlocks, where its data goes and how to get the key; Save, Test connection and Remove. Key files are passed to `aso` as paths and pasted keys through standard input, so the window never stores or shows a secret, and the fields are cleared after saving. Each guide says plainly that this version stores and tests the key while the features that use it are still to come.

Release markers and the Changes report, popularity, publishing, the AI writer, revenue and the Apple Ads website session follow when the engine gains them.
