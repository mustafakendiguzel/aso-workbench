# Changelog

All notable changes are listed here, newest first. Versions follow [Semantic Versioning](https://semver.org):
**major** for changes that break your data or workflow, **minor** for new features, **patch** for fixes.
The in-app updater shows the section of the new version as its release notes.

## [Unreleased]

### Added
- The popularity model outside the macOS app: with the OpenRouter key, terms that are not on Apple's list get the bundled model's estimate from public signals (autocomplete, results, Jev) in `aso popularity`, `aso measure` and `aso expand`: a published-range value capped under the list's lowest score ("~N"), or the 6–29 demand rank among terms below the range, each with its probability. The models are the app's CoreML files, read without CoreML. Keyword coverage uses the 6–29 rank as the macOS writer does. The Windows and Linux window shows estimates as "~N" with the model's confidence in the inspector.
- Trying keywords in other countries outside the macOS app: `aso expand` measures the market's keywords (or `--keywords`) in other storefronts in one pass, rank, Apple popularity, difficulty and Jev's language fit, and where the store speaks another language first asks the writer's model how locals search for the same need (local forms, measured like the rest; `--no-local-forms` skips them). Cells with Apple-level demand and a top-30 rank or beatable results are marked as candidates; `--track` keeps every measured cell as a tracked keyword with its measurement and popularity (the market is created when missing, a local form gets a note). The Windows and Linux window has Try in other countries on the Keywords tab.
- The update check outside the macOS app: `aso update check` shows a newer GitHub release with its notes, the release page and the package for Windows, Linux or macOS; `--automatic` honours the `checkForUpdates` setting and a version skipped with `aso update skip`. The Windows and Linux window checks at start-up, shows a newer release in the sidebar (notes, release page, download, Skip, Later) and has Check for updates in Settings. Before a data file from an older version is migrated, the engine copies it to `Backups/` (the newest five are kept).
- The AI metadata writer outside the macOS app (with the OpenRouter key and the `writerModel` setting): `aso metadata write` gives three proposals for a locale from its market's keyword plan and evidence, the competitors in its tracked queries, the store description and the app's other locales, each repaired and scored by the rules (`--save` keeps the best as the draft); `metadata improve` is Make better and refuses a version that would score lower; `metadata write-all` writes every locale in turn and saves each best proposal; `metadata whats-new` translates release notes into the other locales. The Windows and Linux window's Metadata tab gains the Write menu: Write this locale with AI, Make better (with undo), Write all locales and What's New for all locales.
- Keyword coverage outside the macOS app: `aso metadata show` ranks the market's tracked keywords into the writer's tiers (winnable now, reachable, popular but hard) and shows which ones the draft covers and which are not for this listing. The Windows and Linux window has the Keyword coverage card on the Metadata tab.
- Publishing to App Store Connect outside the macOS app: `aso metadata pull` reads every locale as the baseline (and the privacy policy address for the legal footer), `metadata versions` and `metadata create-version` show and create the editable version, `metadata plan` is the confirm step (what would be sent and why it would be refused, read from Apple without writing), and `metadata apply` and `metadata apply-all` write only with `--yes`: they refuse when the listing changed on Apple since the pull, create missing locales and copy screenshots into them when asked, re-read what Apple holds and keep it as the baseline. `metadata log` lists every attempt, and an applied one becomes a `change` marker on the timeline. The Windows and Linux window's Metadata tab gains Pull and Publish (this locale or every draft) with the plan to confirm, creating the next version, and the result per locale.
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

### Fixed
- A proposal from the AI writer no longer empties the draft's What's New when it is used.

### Development
- The popularity estimator's rules (no suggestions means below the range, the 0.65 gate, the 30–100 clamp, the 6–29 rank, the cap under the list's floor) moved from the app into `ASOCore`, with tests. `TreeModel` reads the CoreML tree-ensemble pipelines straight from the `.mlmodel` files; a macOS test checks it against CoreML on the bundled models. Nothing changes in the app.
- Trying keywords in other countries: the local-forms prompt and its parsing, the opportunity score and the candidate rule moved from the app into `ASOCore`, with tests. Nothing changes in the app.
- Reading a GitHub release (its notes, the package for each platform, GitHub-only links) moved from the app's update checker into `ASOCore` and `ASOProviders`, with tests. When a release carries Windows and Linux packages too, the app still downloads its own disk image.
- The AI writer (prompts, parsing, the repair steps, ranking, the Make better guard and release-note translation) moved from the app into `ASOCore` behind a small model protocol, with tests against a scripted model. The app gathers the same inputs and calls it.
- The writer's keyword plan (tiers, order, phrase coverage) moved from the app into `ASOCore`, with tests; the coverage test now checks the real rule instead of a copy. Nothing changes in the app.
- The checks around applying a listing (editable version states, the changed-since-pull check, the payload, applied or partial after the re-read, the timeline title) moved from the app into `ASOCore`, with tests. Nothing changes in the app.
- Matching a RevenueCat project to an app (bundle ID, then name) moved from the app into `ASOCore`, with tests. Nothing changes in the app.
- Mining keyword phrases from listing text moved from the app's discovery into `ASOCore`, with tests. Nothing changes in the app.
- Continuous integration on macOS builds the whole package, runs the tests and bundles the app for every pull request.
- `ASOCore` and `ASOProviders` no longer depend on Apple-only frameworks when built elsewhere: on Linux and Windows the package uses Apple's API-compatible swift-crypto instead of CryptoKit and leaves out the macOS app. The macOS build still has no dependencies.
- Continuous integration on Linux builds and tests `ASOCore` and `ASOProviders` with Swift 6.2 and 6.4.
- Tests pin JWT signing, key fingerprints, screenshot checksums and the HTTP client's allow-list and error mapping.
- The impact weighting (keyword value, the visibility curve, gains and value tiers) moved from the app's Changes view into `ASOCore`, with tests. Nothing changes in the app.
- The ratings trend (latest count, change, last new rating) and the rule for skipping a repeated reading moved from the app into `ASOCore`, with tests. Nothing changes in the app.
- Rank history (Δ and before/after), keyword verdicts (brand, golden, lead) and idea gaps moved from the app's data model into `ASOCore`, with tests, so every platform computes them the same way. Nothing changes in the app.

### Docs
- The Apple Ads website's exact-term index is documented as macOS-only: the app signs in to the Apple Ads website in an embedded browser to read it, which the command line and the Windows and Linux window do not have; there, terms off Apple's list get the model estimate.
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
