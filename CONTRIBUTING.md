# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Before you start

- Open an issue first for anything bigger than a small fix, so we can agree on the shape.
- By contributing you agree that your contribution is licensed under this repository's license (MIT with the Commons Clause).

## Build and test

```bash
make bundle     # debug build → build/ASO Workbench.app
make open       # build and launch
make test       # unit tests (live Apple tests are opt-in, see Tests/ASOProvidersTests/LiveAppleAdsTests.swift)
make lab        # launch with the developer Lab (model training, URL commands)
```

Requirements: macOS 15+, Xcode 26 (Swift 6.2). No third-party dependencies on macOS. `ASOCore` and `ASOProviders` must stay portable to other platforms, see [Platforms](docs/ARCHITECTURE.md#platforms).

## Ground rules

These keep the numbers trustworthy, please keep them in any change:

1. **Every number shows its source.** Apple's value, a public-search value and a model estimate are never mixed without a label.
2. **Absence is not zero.** "Not in the top 200", "no record" and "request failed" are separate states.
3. **Storefront ≠ language.** The Japanese store and the Japanese language are different settings.
4. **Nothing is written to Apple without an explicit, confirmed action**, and every write is re-read.
5. **Keys go only to their own service** and never into logs, exports or the data file.
6. **Layers stay separate:** `ASOCore` (pure logic, no network, no UI) → `ASOProviders` (network adapters) → `ASOWorkbench` (SwiftUI app). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Pull requests

- One topic per pull request, with a short description of *why*.
- `make test` passes; new logic in `ASOCore` comes with a test.
- UI text is English, short and concrete; say what a button does.
- Update `CHANGELOG.md` under an "Unreleased" heading.
