# Command line (`aso`)

`aso` is the ASO Workbench engine without the macOS interface. It uses the same rules as the app (`ASOCore`) and the same App Store adapters (`ASOProviders`), keeps its own data file, and is the foundation for the Windows and Linux versions. It builds on every platform listed under [Platforms](ARCHITECTURE.md#platforms).

The same honesty rules apply: "> 200" means *not in the top 200 results* (never rank 201), a failed request is stored as a failure, and a number that has no source is left empty instead of guessed.

## Build

```bash
swift build -c release --product aso
.build/release/aso --help
```

See [Platforms](ARCHITECTURE.md#platforms) for the toolchain and system libraries each platform needs.

## Commands

| Command | What it does |
|---|---|
| `aso app search <name, link or ID> [--country CC]` | Finds apps by name, or the app behind a link or ID. Nothing is stored. |
| `aso app add <App Store link or ID> [--country CC] [--markets US,DE,…] [--device iphone\|ipad\|mac]` | Starts tracking an app (looked up in the link's country, else `--country`, else US), optionally with one market per country. Its Apple Ads genre follows its App Store category. |
| `aso app list` | Tracked apps. |
| `aso app genre <app ID> <GENRE\|any>` | The Apple Ads genre whose popularity lists are used (`aso genres` lists them); `any` searches every genre. |
| `aso app remove <app ID>` | Stops tracking an app and deletes its keywords and measurements. |
| `aso market add <app ID> --country CC [--device ...]` | Adds a market (one App Store country and device). |
| `aso market list <app ID>` | The app's markets with their keyword count and last measurement. |
| `aso market remove <app ID> --country CC [--device ...]` | Removes a market with its keywords and measurements. |
| `aso storefronts` · `aso genres` | The App Store countries and the Apple Ads genres, for pickers. |
| `aso keywords add <app ID> <keyword>... --country CC [--device iphone\|ipad\|mac]` | Tracks keywords in one market. Duplicates (ignoring case and spacing) are skipped. |
| `aso keywords remove <app ID> <keyword>... --country CC [--device ...]` | Stops tracking keywords. |
| `aso keywords list <app ID> [--country CC] [--device ...] [--delta lastMarker\|previous\|first\|week] [--csv]` | Latest rank, Δ, popularity, difficulty and brand verdict per keyword. `--csv` writes the macOS app's CSV columns. |
| `aso keywords show <app ID> <keyword> --country CC [--device ...]` | The inspector: every measurement, latest and best rank, the latest top ten with your app marked, competition signals and difficulty components. |
| `aso keywords note <app ID> <keyword> --country CC [--device ...] --text TEXT` | Saves a note on the keyword; an empty text clears it. |
| `aso measure <app ID> [--country CC] [--device ...] [--depth 1-200] [--keywords a,b]` | A fresh rank check for every keyword (or only those listed), about 3 seconds each (Apple limits public search). It first reads the app's ratings, a new release and new reviews in the measured storefronts, as the macOS app does, so the measurement lands after the release marker, and with the Apple Ads keys it refreshes the measured keywords' popularity afterwards. Progress goes to stderr. |
| `aso popularity <app ID> [--country CC] [--device ...] [--keywords a,b]` | Apple Ads popularity (1–100, relative within the country) for every keyword, or only those listed, from Apple's list for the app's genre (`aso app genre`; with `any`, every genre's list, keeping each term's highest score). The scores describe the last full month, because Apple publishes them with a delay. A term that is not on the list is *below the published range* and is shown as "< N", where N is the list's lowest score that month, never as a guessed number. Markets in the same country share one lookup, and every reading is kept. Needs the Apple Ads keys; `measure` runs it for the measured keywords when they are stored. |
| `aso ratings check <app ID> [--country CC,… \| --all]` | Reads the rating count and average in each storefront: the app's markets, the countries given, or all of them. A reading that repeats the previous one within the hour is not stored. |
| `aso ratings list <app ID>` | Per storefront: the latest count and average, the change since the previous reading and when a new rating last arrived. |
| `aso reviews check <app ID> [--country CC,… \| --all]` | Reads the newest written reviews from Apple's public feed. Reviews not seen before are stored and marked new (the app's first check is history, not news); the next check clears the marks. When no storefront answers, nothing changes. |
| `aso reviews list <app ID> [--country CC] [--min-rating 1-5] [--new] [--search TEXT]` | Stored reviews, newest first, with totals per star. |
| `aso competitors <app ID> --country CC [--device ...] [--depth 1-50]` | Apps in the latest successful results of the market's tracked keywords (top 10 by default), by how many keywords they appear in, then average position. Only tracked searches count: this is not a competitor's full keyword set. |
| `aso markers list <app ID>` | The timeline, newest first: App Store releases and notes. A release is recorded when `measure` or `ratings check` sees a version not looked at before (the first look records the current one), dated with Apple's release date; a removed release is not added back. |
| `aso markers add <app ID> --title TEXT [--date DATE]` | Pins a note ("keywords updated", "new screenshots") to compare ranks around. `DATE` is `2026-10-20` (midnight UTC) or `2026-10-20T14:30:00Z` (an offset such as `+02:00` works too); now by default, never in the future. |
| `aso markers remove <app ID> <marker ID>` | Removes a release or note from the timeline; measurements are kept. |
| `aso impact <app ID> <marker ID>` | Every keyword measured both before and after the marker: the last rank before it, the latest after it, Δ, and what the move is worth. Value = popularity × (1 − (difficulty/100)²) × fit (0 for brands and unrelated terms), gain = visibility change × value / 100, with the totals gained, lost and net. |
| `aso ads sync [--days 1-90]` | Your own Apple Ads results (Campaign Management API, the same keys as popularity): for every campaign that promotes a tracked app, the keyword report of the last 30 days by default, per keyword and storefront. A sync replaces that campaign's stored rows; campaigns for other apps are skipped. |
| `aso ads list <app ID>` | The stored results per storefront (impressions, taps, installs, spend, cost per install, tap-to-install rate) and per keyword, biggest spend first. Each keyword's totals for its storefront also appear in `keywords list --json` and `keywords show`. |
| `aso discover <app ID> --country CC [--device ...] [--competitor LINK\|ID] [--seeds a,b] [--difficulty 0-60]` | Golden keyword candidates, as the macOS app's finder: App Store autocomplete around the seeds (by default the market's most popular tracked keywords and the app's title words) and Apple Ads suggestions, or the words and two-word phrases of a competitor's title and description. Candidates get Apple popularity, Jev (with the OpenRouter key) drops other brands and unnatural phrases and judges the fit against your app's description, and the most promising untracked ones (25 by default) are searched for difficulty, about 3 seconds each. Golden: popularity and difficulty within the settings, not a brand, and a fit; a *lead* passes the numbers but does not fit your app. Without the Apple Ads keys nothing has popularity, so nothing is golden. Nothing is stored; add keywords with `keywords add`. With `--json`, progress goes to stderr as JSON Lines. |
| `aso search <term> --country CC [--device ...] [--limit 1-200]` | Top results for a term right now. Nothing is stored. |
| `aso hints <seed> --country CC` | App Store autocomplete for a prefix. |
| `aso difficulty <term> --country CC [--device ...]` | Difficulty (0–100) from the top ten results, with every component. |
| `aso validate [--title T] [--subtitle S] [--keywords K]` | Checks metadata against the App Store limits; exits with 1 when a hard limit is broken. |

A quick start:

```bash
aso app add "https://apps.apple.com/us/app/keynote/id361285480"
aso keywords add 361285480 "presentation" "slides maker" --country US
aso measure 361285480
aso keywords list 361285480
```

Keywords that start with `-` go after `--`: `aso keywords add 361285480 --country US -- -keyword`.

## Output and exit codes

- Text by default; `--json` prints machine-readable JSON on stdout (dates in ISO 8601; an absent value, such as the rank of a keyword outside the results, is left out rather than written as a number). Progress, warnings and errors always go to stderr, so JSON output can be piped.
- With `--json`, `measure` writes its progress to stderr as JSON Lines, one object per measured keyword:
  `{"completed":1,"keyword":"notes","market":"US · iphone","outcome":"#12","status":"found","total":20}` (`status` is `found`, `outside`, `failed` or `notChecked`).
- `difficulty --json` gives the score, its tier, the sample size and every component with its name, weight and explanation, exactly as the engine weighs them.
- Exit codes: `0` success, `1` the command failed (the message says why), `64` the command was called wrongly (the usage follows). `validate` exits with `1` when a hard limit is broken and still prints the issues.
- Global options (`--json`, `--data-dir`) may come before the command; keywords and terms that start with `-` go after `--`.

## Settings

`aso settings` shows the preferences with what each accepts; `aso settings set <setting> <value>` changes one; `aso settings reset` restores the defaults. They are the macOS app's preferences with its defaults, stored in `settings.json`:

| Setting | Default | Used by |
|---|---|---|
| `resultDepth` | 200 (50, 100 or 200) | `measure`, unless `--depth` says otherwise |
| `pacingSeconds` | 3.1 (1–6) | every public search; the API allows roughly 20 requests a minute |
| `goldenMinPopularity`, `goldenMaxDifficulty` | 30, 45 | the golden verdict in `keywords list` |
| `writerEasyDifficulty`, `writerMaxDifficulty` | 35, 55 | the metadata writer's tiers |
| `deltaReference` | `lastMarker` (`previous`, `first`, `week`) | Δ in `keywords list`, unless `--delta` says otherwise |
| `autoMeasureOnLaunch`, `staleHours` | false, 20 (6–72) | front ends at start-up; `measure --stale` |
| `writerModel` | `deepseek/deepseek-v4-pro` | the metadata writer |
| `adsReferenceAppID` | empty | the Apple Ads website session |

`aso measure --stale [--stale-hours N]` measures every market, across all apps, whose newest measurement is older than `staleHours` (or that was never measured).

## Connections

`aso connections` lists which services have keys, with their identifiers and the public-key fingerprint, never a secret. Keys are read from a file or from standard input, **never from arguments**, because other users of the computer can see a process's arguments:

```bash
aso connections set apple-ads --client-id SEARCHADS.… --key-id … --org-id … --key-file aso-ads-private.pem
aso connections set asc --issuer-id … --key-file AuthKey_2X9R4HXF34.p8      # the key ID is read from Apple's file name
aso connections set openrouter --key-stdin < openrouter.txt
aso connections set revenuecat --keys-file revenuecat-keys.txt               # one key per line
aso connections verify apple-ads
aso connections remove openrouter
```

Keys are checked before they are stored (identifiers present, private keys parsed as P-256 keys). They live in `credentials.json` in the data folder, in the same shape the macOS app writes, readable only by your user (folder 0700, file 0600 where the system has POSIX permissions), and each goes only to its own service. The Apple Ads keys power `aso popularity`, `aso ads` and the popularity in `aso discover`, the OpenRouter key its brand and fit checks; the features that use the others (publishing, the writer, revenue) come to the command line in later versions.

## Data

The data file is `engine.sqlite` in the data folder:

| Platform | Default folder |
|---|---|
| macOS | `~/Library/Application Support/ASO Workbench/` |
| Linux | `$XDG_DATA_HOME/ASO Workbench/` (usually `~/.local/share/ASO Workbench/`) |
| Windows | the user's application data folder, `ASO Workbench\` |

`ASO_DATA_DIR` or `--data-dir PATH` choose another folder. The file is plain SQLite: back it up by copying it while `aso` is not running, start over by deleting it. On macOS it sits next to the app's `store.sqlite` but never shares its format; the app does not read it.

The schema is versioned (`PRAGMA user_version`) and migrated forward automatically. A data file written by a newer version is refused rather than rewritten.

## Not yet in the command line

Publishing (App Store Connect), the AI writer (OpenRouter) and revenue (RevenueCat) need keys and arrive in later steps. Of the macOS app's popularity layers, the command line has Apple's lists and the "< N" bound; the Apple Ads website's exact-term index and the model estimate for terms below the range come later. Without the Apple Ads keys `popularity` is left out, no keyword is marked golden, because golden needs a popularity value, and every keyword in `aso impact` is worth 0, so its totals stay at 0 while the rank moves are still listed. Metadata applied from the macOS app is not on the command line's timeline.
