# Changelog

All notable changes are listed here, newest first. Versions follow [Semantic Versioning](https://semver.org):
**major** for changes that break your data or workflow, **minor** for new features, **patch** for fixes.
The in-app updater shows the section of the new version as its release notes.

## [Unreleased]

### Added
- Metadata drafts outside the macOS app: `aso metadata locales|show|draft|baseline|reset` keeps a draft and a baseline (what is live on the App Store, typed in) per locale, with the counters, the ASO rules score and findings, validation, and the changes against the baseline (keywords as added, removed and kept). `metadata legal` and `metadata footer` keep the Terms of Use and Privacy Policy links and append them to each locale's description in its own language, `metadata fill-whats-new` gives empty release notes the default note in their language, and `aso locales` lists the listing languages. Nothing is sent to Apple. The Windows and Linux window's Metadata tab becomes the editor: a locale picker, the six fields saved as you type with their counters, the rules, the changes, the baseline and the legal footer.
- RevenueCat revenue outside the macOS app: `aso revenue refresh` reads every project's MRR, active subscriptions, 28-day revenue, new customers and trials (one snapshot per project and day), and `aso revenue show` finds the app's project by bundle ID, then by name, with the MRR change since the previous day and the daily history. The Windows and Linux window has the Revenue card on the Overview, read at start-up and on Refresh.
- Your own Apple Ads campaign results outside the macOS app: `aso ads sync` reads the last 30 days (or `--days`) of every campaign that promotes a tracked app, and `aso ads list` shows impressions, taps, installs, spend, cost per install and tap-to-install rate per storefront and per keyword. `aso keywords list` and `keywords show` include each keyword's own results. The Windows and Linux window has the Apple Ads card on the Overview and an Ads column and inspector line on the Keywords tab.
- Keyword discovery outside the macOS app: `aso discover` finds golden keyword candidates from App Store autocomplete and Apple Ads suggestions around your best keywords, or from a competitor's title and description (`--competitor`), with Apple popularity, Jev's brand, naturalness and fit checks (with the OpenRouter key) and difficulty for the most promising. Nothing is stored until you add keywords. The Windows and Linux window has Find keywords on the Keywords tab and Import keywords on the Competitors tab.
- Apple Ads popularity outside the macOS app: `aso popularity` reads Apple's country list for the app's genre (or every genre) and marks terms that are not on it as below the published range, under the list's lowest score. `aso measure` refreshes the measured keywords afterwards when Apple Ads is connected. Popularity appears in `aso keywords list` and `keywords show`, fills the CSV's popularity columns, and makes golden verdicts, opportunity and the value in `aso impact` work. The Windows and Linux window shows popularity in the keyword table and inspector and reads it with Ctrl+Shift+P.
- Release markers and their effect outside the macOS app: the App Store release is recorded as a marker when `aso measure` or `aso ratings check` sees a new version (dated with Apple's release date), `aso markers list|add|remove` keeps notes on the same timeline, Δ `lastMarker` compares against the latest one, and `aso impact` shows the ranks before and after a marker, weighted by what each keyword is worth. The Windows and Linux window gains a Changes tab.
- Ratings, written reviews and competitors outside the macOS app: `aso ratings check|list` (rating count and average per storefront, change since the last check, when a new rating last arrived), `aso reviews check|list` (Apple's public feed; reviews not seen before are marked new, with storefront, rating, new-only and text filters) and `aso competitors` (apps in the latest results of the tracked keywords). `aso measure` reads ratings and new reviews in the measured storefronts first, as the macOS app does. The Windows and Linux window gains a ratings card on the Overview and Competitors and Reviews tabs.
- The keyword table and inspector outside the macOS app: `aso keywords show` (history, best rank, top ten, signals, difficulty), `keywords note`, `measure --keywords` and `keywords list --csv` (the macOS CSV). The Windows and Linux window gains filters, multi-select (measure, copy, remove), CSV export and an inspector with the rank chart, top results, note and measurement log.
- Apps and markets outside the macOS app: `aso app search`, `app add --markets --device`, `app genre`, `market add|list|remove`, `storefronts` and `genres`. The Windows and Linux window gains an Add App dialog (search by name, device, several markets), an Overview with the Apple Ads genre and the markets, and a Keywords view per market.
- Settings and connections outside the macOS app: `aso settings` (the app's preferences and defaults) and `aso connections` (store, inspect, test and remove the Apple Ads, App Store Connect, OpenRouter and RevenueCat keys; keys only from files or standard input). The Windows and Linux window has a Settings tab with General, Measurement and Connections, connection dots in the sidebar, and the start-up refresh of markets not measured recently (`aso measure --stale`).
- A window for Windows and Linux (`desktop/`, C# and Avalonia) on top of `aso`: tracked apps, keywords with rank, Δ, difficulty and brand verdicts, rank measurement with progress, search, autocomplete, difficulty components and the metadata check. See [docs/DESKTOP.md](docs/DESKTOP.md).
- `aso measure --json` reports progress as JSON Lines on stderr, and `aso difficulty --json` includes every component with its weight and explanation.
- `aso`, the engine on the command line: track apps and keywords, measure ranks, list them with Δ, difficulty and brand verdicts, and look up search results, autocomplete, difficulty and metadata limits. Text or `--json` output; its own SQLite data file. See [docs/CLI.md](docs/CLI.md).

### Changed
- The AI writer no longer uses em or en dashes as punctuation, and list lines in descriptions and What's New start with "•".
- Interface text uses commas, colons and periods instead of em dashes.

### Development
- Matching a RevenueCat project to an app (bundle ID, then name) moved from the app into `ASOCore`, with tests. Nothing changes in the app.
- Mining keyword phrases from listing text moved from the app's discovery into `ASOCore`, with tests. Nothing changes in the app.
- Continuous integration on macOS builds the whole package, runs the tests and bundles the app for every pull request.
- `ASOCore` and `ASOProviders` no longer depend on Apple-only frameworks when built elsewhere: on Linux and Windows the package uses Apple's API-compatible swift-crypto instead of CryptoKit and leaves out the macOS app. The macOS build still has no dependencies.
- Tests pin JWT signing, key fingerprints, screenshot checksums and the HTTP client's allow-list and error mapping.
- The impact weighting (keyword value, the visibility curve, gains and value tiers) moved from the app's Changes view into `ASOCore`, with tests. Nothing changes in the app.
- The ratings trend (latest count, change, last new rating) and the rule for skipping a repeated reading moved from the app into `ASOCore`, with tests. Nothing changes in the app.
- Rank history (Δ and before/after), keyword verdicts (brand, golden, lead) and idea gaps moved from the app's data model into `ASOCore`, with tests, so every platform computes them the same way. Nothing changes in the app.

### Docs
- README in English, Turkish, Simplified Chinese, Japanese, Korean, Spanish and German.
- Demo video in the README.
- The popularity section explains how the estimate model was trained, including the Jev clues.

## [1.0.0] - 2026-09-22

First public release.

### Track
- Rank tracking per country and device from public App Store search (top 200), with gaps shown as gaps.
- Rank history chart with release and change markers; Δ against the last release, the previous or first measurement, or 7 days ago.
- Automatic release detection and a timeline of releases, applied metadata changes and your own notes, with a value-weighted before/after report.
- Ratings per storefront over time and written reviews from Apple's public feed.

### Research
- Popularity in layers: Apple's monthly Search Term Rank lists, the optional Apple Ads website index, and a bundled model estimate for everything else.
- Difficulty (0–100) from the top ten public results, with every component shown.
- Golden keywords, relevance ("Fit") and brand detection, competitor keyword import, autocomplete ideas.
- Try your keywords in other countries, including AI-suggested local-language forms, and track the winners in one click.

### Write and publish
- AI metadata writer ranked by winnable keywords first, "Make better", write all locales, What's New for every language.
- Rule engine for title, subtitle and keyword field (no filler, no repeats, room used), per storefront.
- Publish to App Store Connect: create missing languages, copy screenshots, create the next version, re-read after writing.
- Legal footer (Terms of Use and Privacy Policy) added to every description automatically.

### Measure
- Your Apple Ads campaign results per keyword and country.
- MRR and subscriptions from RevenueCat.

### App
- New name: ASO Workbench (early private builds were called ASO Studio; their data folder and settings move over automatically on first launch).
- Update checker for new GitHub releases; automatic data backup before a new version first opens the data.
- Clear connection guide: what each key unlocks, where data goes, how to get it.
