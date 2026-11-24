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

The first version covers what the engine offers today: tracked apps, keywords per market with rank, Δ, difficulty and brand verdicts, rank measurement, search results, autocomplete, difficulty with every component, and the metadata check. Popularity, publishing, the AI writer and revenue follow when the engine gains them.
