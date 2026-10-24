<div align="center">

<img src="docs/media/icon.png" width="128" height="128" alt="ASO Workbench icon">

# ASO Workbench

**App Store Optimization on your Mac, with honest numbers.**
Track where your app ranks, find keywords you can actually win, write and publish your listing in every language, and see what each change did.

[![Download](https://img.shields.io/github/v/release/mustafakendiguzel/aso-workbench?label=download&style=flat-square&color=brightgreen)](https://github.com/mustafakendiguzel/aso-workbench/releases/latest)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue?style=flat-square)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange?style=flat-square)
[![License](https://img.shields.io/badge/license-MIT%20%2B%20Commons%20Clause-lightgrey?style=flat-square)](LICENSE)

[Install](#install) · [Quick start](#quick-start) · [Features](#what-it-does) · [Keys](#connections-which-keys-and-why) · [How the numbers work](#how-the-numbers-work) · [FAQ](#faq)

<sub><b>English</b> · <a href="README.tr.md">Türkçe</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.de.md">Deutsch</a></sub>

</div>

<div align="center">
  <a href="docs/media/demo.mp4"><img src="docs/media/demo.gif" width="880" alt="ASO Workbench in action: tracking keywords, checking popularity and difficulty, writing a listing"></a>
  <br>
  <sub>▶ <a href="docs/media/demo.mp4"><b>Watch the full demo</b></a> · the preview above is silent and loops</sub>
</div>

<!-- After the first push you can get an inline player too: edit this README on github.com, drag docs/media/demo.mp4
     onto the line under this comment (GitHub accepts up to 10 MB on free accounts) and commit. -->

---

## Why ASO Workbench

Most ASO tools show one confident number per keyword. Often that number is a guess, and nobody tells you which part is Apple's and which part is the tool's.

ASO Workbench takes a different path:

- **Every number says where it came from.** Apple's own popularity, a public-search measurement and a model estimate carry different badges and are never blended.
- **"Not found" is not "rank 201".** Absence, failure and "not checked" are kept apart.
- **It runs on your Mac.** No account, no server, no telemetry. Your keys stay in one file on your machine.
- **It works without any key** and gets better with each one you add.

## What it does

| | |
|---|---|
| 📈 **Track** | Rank for every keyword, per country and device, from real App Store search (top 200). History chart with your releases on it. Δ against your last release, so gains don't vanish when you re-measure. Ratings per country and written reviews. |
| 🔎 **Research** | Popularity from Apple wherever Apple publishes it, a labelled estimate elsewhere. Difficulty from the top ten results, fully explained. **Golden keywords** (real demand, beatable competition, not someone else's brand, relevant to your app). Import a competitor's keywords. Autocomplete ideas. |
| 🌍 **Go global** | Try your keywords in other countries in one pass, including AI-suggested phrasings in the local language, and track the winners with one click. |
| ✍️ **Write** | An AI writer that fills title, subtitle and keyword field with the keywords you can win first. *Make better* fixes every rule finding. Write every language at once, What's New for all languages, Terms and Privacy links added automatically. |
| 🚀 **Publish** | Send drafts to App Store Connect: missing languages are created, screenshots copied, the next version created, every write read back. Nothing is submitted for review. |
| 🧪 **Measure** | A timeline of releases and changes with a before/after report weighted by keyword value. Your Apple Ads results per keyword and country. MRR and subscriptions from RevenueCat. |

## Install

### Download (easiest)

1. Download **`ASO-Workbench-x.y.z.dmg`** from the [latest release](https://github.com/mustafakendiguzel/aso-workbench/releases/latest).
2. Open it and drag **ASO Workbench** onto **Applications**.
3. The first time, macOS says it can't verify the developer (the app is free and not notarized). Right-click the app → **Open** → **Open**. Or: System Settings → Privacy & Security → **Open Anyway**.

When a new version comes out, the app tells you (bottom of the sidebar, or **ASO Workbench ▸ Check for Updates…**). Your data is backed up automatically before a new version opens it.

### Build from source

Needs macOS 15+ and Xcode 26 (Swift 6.2). No dependencies.

```bash
git clone https://github.com/mustafakendiguzel/aso-workbench.git
cd aso-workbench
make install        # optimized build → /Applications/ASO Workbench.app
```

Later: `make update` pulls the latest code and reinstalls. `make help` lists everything.

## Quick start

1. **Add App** (bottom of the sidebar) → paste your App Store link. The category is filled in for you.
2. **Keywords** → **Add** → type the keywords you care about, one per line.
3. **Update ▸ Measure all** → ranks arrive keyword by keyword (about 3 seconds each; Apple limits public search).
4. Optional: **Connections** → add the Apple Ads key → **Update ▸ Refresh popularity**. Now you see Apple's own popularity.
5. Filters ▸ **Golden** shows the keywords worth fighting for. **Metadata ▸ Write** turns them into a listing.

## Connections: which keys, and why

You don't need any key to start. Each one unlocks something specific; the **Connections** screen explains each in the app, with step-by-step instructions.

| Connection | Need | Unlocks | Cost |
|---|---|---|---|
| *(none)* | not needed | Ranks, autocomplete, competitors, difficulty, ratings, reviews | free |
| **Apple Ads API** | Recommended | Apple's own popularity, your campaign results | free, spends nothing |
| **App Store Connect API** | Optional | Pull and publish your listing in every language | free |
| **OpenRouter** | Optional | AI writer, translations, brand / relevance checks, popularity estimates | pay per use, fractions of a cent |
| **RevenueCat** | Optional | MRR and subscriptions on Overview | free |
| **Apple Ads website session** | Advanced | Apple's exact index for terms missing from the lists (undocumented, at your own risk) | free |

Keys live in one file on your Mac, readable only by you, and each key goes only to its own service. Details and how to get each key: **[docs/CONNECTIONS.md](docs/CONNECTIONS.md)**.

## How the numbers work

### The numbers, explained simply

| Number | Plain meaning | Good is |
|---|---|---|
| **Rank** | Where your app appears when someone searches this word. | low (#1 is best) |
| **Popularity** (5–100) | How many people search this word, on Apple's scale. | high |
| **Difficulty** (0–100) | How hard it is to reach page one, measured by how big and focused the apps already there are. | low |
| **Opportunity** | Popularity, discounted by difficulty: popularity × (1 − (difficulty ÷ 100)²). | high |
| **Fit** | How likely someone searching this wants an app like yours. | related (≥ 50%) |
| **Golden ★** | Popularity ≥ 30, difficulty ≤ 45, not a brand, related to your app. | ★ |

### Popularity: Apple first, estimate second

Apple publishes a 1–100 popularity only for the top of each genre (monthly lists), and since 29 September 2025 reports **5** for everything below. ASO Workbench shows, in order:

1. **Apple's list value** (badge `Apple`, needs the Apple Ads key),
2. **Apple's exact index** (badge `Apple · index`, optional website session),
3. **a model estimate** (badge `Derived · est.`), and for Apple's "5" a **6–29 rank among floor terms** so you can still compare them,
4. otherwise **"< N"**: below the lowest listed score.

The estimate comes from a model we trained ourselves and ship inside the app:

1. **Data.** About 55,800 search terms from five countries (US, GB, DE, FR, TR).
2. **Answer key.** Each term is labelled with Apple's real popularity.
3. **Clues.** Each term is described with public clues only: autocomplete, search results, and **Jev**. Jev (TypeSafe Jev, a small classification model reached through OpenRouter) answers narrow questions with probabilities, such as "is this a brand?", "does it sound like real demand?" and "which genre is it?".
4. **Training.** Two small CreateML models learned to predict Apple's number from those clues. They ship with the app, so you never have to train anything.

In use, Jev answers the same questions for your new terms, which is why the estimate needs the OpenRouter key. On terms it never saw, the model ranks them in the same order as Apple with a correlation of **0.74** and is off by about **10 points** on a typical term. It is an aid for ordering, always labelled, and Apple's number always wins. **[The full method and test results →](docs/POPULARITY.md#the-model-step-by-step)**

### Difficulty

Computed from the **top ten** public results, the ones a searcher actually sees. It weighs how big the top three are (35%), how big the rest of page one is (20%), how many name the keyword in their title (20%), how established (10%), how actively updated (10%) and how well rated (5%) they are, with a discount when Apple fills the page with unrelated apps. The keyword inspector shows every part. **[Details →](docs/POPULARITY.md#difficulty)**

### Before / after

Every release (detected automatically), every change you publish and every note you add becomes a marker. The **Changes** page compares ranks before and after it, weighted by each keyword's value. Climbing 50 places on a term nobody searches counts for nothing.

## Privacy and security

- Runs locally. No ASO Workbench server, no account, no analytics.
- The app talks only to an allow-listed set of hosts (Apple, OpenRouter, RevenueCat, GitHub for update checks). See the [full list](SECURITY.md).
- Nothing is written to App Store Connect without your confirmation; every write is re-read; nothing is submitted for review.
- Keys: `~/Library/Application Support/ASO Workbench/credentials.json` (permissions 600). Data: `store.sqlite` in the same folder, a plain SQLite file you can back up or delete.

See **[SECURITY.md](SECURITY.md)**.

## Project structure

```
Sources/
├── ASOCore/        pure logic: models, rules, difficulty, diffs, features (no network, no UI)
├── ASOProviders/   Apple, OpenRouter and RevenueCat adapters behind an allow-listed HTTP client
└── ASOWorkbench/   the SwiftUI app: screens, services, SwiftData model, design system
Resources/          Info.plist, icon, bundled popularity model
scripts/            bundle-app.sh (build the .app), release.sh (.dmg + GitHub release)
docs/               POPULARITY, CONNECTIONS, ARCHITECTURE, RELEASING
```

Three layers the compiler keeps apart, Swift 6 strict concurrency, zero dependencies. **[Architecture →](docs/ARCHITECTURE.md)**

## Development

```bash
make open      # debug build and launch
make test      # unit tests
make lab       # launch with the developer Lab (retrain the popularity model)
make dist      # build the .dmg and .zip for a release (maintainers)
```

Releases, versioning and how updates reach users: **[docs/RELEASING.md](docs/RELEASING.md)**. Contributions: **[CONTRIBUTING.md](CONTRIBUTING.md)**. Changes: **[CHANGELOG.md](CHANGELOG.md)**.

## FAQ

**Why do my numbers differ from other ASO tools?**
Because Apple publishes very little below the top of each genre, other tools fill the gap with their own estimates, usually without saying so. ASO Workbench shows Apple's value when Apple has one and labels everything else.

**Does connecting Apple Ads cost money?**
No. The popularity and report endpoints are read-only and need no running campaign.

**Can it break my App Store listing?**
It writes only when you press Apply and confirm, refuses if the listing changed since you last pulled it, re-reads after writing, and never submits for review.

**Why macOS 15?**
It uses SwiftData, the SwiftUI inspector and Swift 6 features that need macOS 15.

**Where is my data? How do I start over?**
`~/Library/Application Support/ASO Workbench/`. Quit the app and delete `store.sqlite` to start over; delete `credentials.json` to remove every key.

## License

**Free to use, not to sell.** MIT License with the Commons Clause: you may use ASO Workbench for free (also for your own commercial apps), read and change the code, and share it with this license attached. You may not sell it, a modified copy, or a paid service built mostly on it. See [LICENSE](LICENSE).

ASO Workbench is not affiliated with or endorsed by Apple. App Store, Apple Ads and App Store Connect are trademarks of Apple Inc.

<div align="center"><sub><b>English</b> · <a href="README.tr.md">Türkçe</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.de.md">Deutsch</a></sub></div>
