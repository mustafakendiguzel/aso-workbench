import Foundation
import ASOCore

/// The engine's data file: one SQLite database holding tracked apps, markets, keywords and every rank observation.
/// Observations are only ever added, never overwritten, like the macOS app's store.
public actor Store {
    private let db: Database

    /// Schema migrations, applied in order; `PRAGMA user_version` records how many have run.
    /// Append new steps, never edit shipped ones.
    static let migrations: [String] = [
        """
        CREATE TABLE apps (
            track_id INTEGER PRIMARY KEY,
            bundle_id TEXT,
            name TEXT NOT NULL,
            seller_name TEXT NOT NULL,
            icon_url TEXT,
            primary_genre TEXT,
            store_version TEXT,
            created_at REAL NOT NULL
        );
        CREATE TABLE markets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id INTEGER NOT NULL REFERENCES apps(track_id) ON DELETE CASCADE,
            country_code TEXT NOT NULL,
            device TEXT NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE (app_id, country_code, device)
        );
        CREATE TABLE keywords (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            market_id INTEGER NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
            text TEXT NOT NULL,
            normalized TEXT NOT NULL,
            created_at REAL NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            brand_probability REAL,
            fit_probability REAL,
            navigational REAL,
            UNIQUE (market_id, normalized)
        );
        CREATE TABLE rank_observations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword_id INTEGER NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
            fetched_at REAL NOT NULL,
            provider TEXT NOT NULL,
            device TEXT NOT NULL,
            outcome_kind TEXT NOT NULL,
            position INTEGER,
            observed_count INTEGER NOT NULL,
            failure_reason TEXT,
            results BLOB NOT NULL,
            signals BLOB
        );
        CREATE INDEX rank_observations_keyword ON rank_observations (keyword_id, fetched_at);
        """,
        // 2: the Apple Ads genre popularity lookups use (raw AppleAdsGenre value; NULL = search every genre).
        "ALTER TABLE apps ADD COLUMN ads_genre TEXT;",
        // 3: rating readings per storefront, and written reviews keyed like the macOS app ("<country>|<feed id>").
        """
        CREATE TABLE ratings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id INTEGER NOT NULL REFERENCES apps(track_id) ON DELETE CASCADE,
            country_code TEXT NOT NULL,
            count INTEGER NOT NULL,
            average REAL,
            fetched_at REAL NOT NULL
        );
        CREATE INDEX ratings_app ON ratings (app_id, country_code, fetched_at);
        CREATE TABLE reviews (
            app_id INTEGER NOT NULL REFERENCES apps(track_id) ON DELETE CASCADE,
            review_id TEXT NOT NULL,
            country_code TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            rating INTEGER NOT NULL,
            author TEXT NOT NULL,
            version TEXT,
            date REAL,
            fetched_at REAL NOT NULL,
            is_new INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (app_id, review_id)
        );
        """,
        // 4: release markers (App Store releases seen by a lookup, and notes), and the version last looked at for a
        // release, so a release marker that was removed is not added back.
        """
        CREATE TABLE markers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id INTEGER NOT NULL REFERENCES apps(track_id) ON DELETE CASCADE,
            date REAL NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            version TEXT,
            country_code TEXT
        );
        CREATE INDEX markers_app ON markers (app_id, date);
        ALTER TABLE apps ADD COLUMN release_checked_version TEXT;
        """,
        // 5: popularity readings from Apple Ads, kept like rank observations (added, never overwritten).
        """
        CREATE TABLE popularity_readings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword_id INTEGER NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
            fetched_at REAL NOT NULL,
            country_code TEXT NOT NULL,
            genre TEXT,
            period_start REAL NOT NULL,
            period_end REAL NOT NULL,
            popularity INTEGER,
            popularity_1to5 INTEGER,
            popularity_in_genre INTEGER,
            rank_in_genre INTEGER,
            source TEXT NOT NULL,
            upper_bound INTEGER,
            any_genre INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX popularity_readings_keyword ON popularity_readings (keyword_id, fetched_at);
        """,
        // 6: the advertiser's own Apple Ads keyword results, one row per campaign keyword and storefront for the synced
        // window; a sync replaces a campaign's rows.
        """
        CREATE TABLE ads_keyword_stats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id INTEGER NOT NULL REFERENCES apps(track_id) ON DELETE CASCADE,
            campaign_id INTEGER NOT NULL,
            campaign_name TEXT NOT NULL,
            ad_group_name TEXT NOT NULL,
            keyword_id INTEGER NOT NULL,
            keyword TEXT NOT NULL,
            normalized TEXT NOT NULL,
            match_type TEXT NOT NULL,
            status TEXT NOT NULL,
            country_code TEXT NOT NULL,
            bid REAL,
            currency TEXT NOT NULL,
            impressions INTEGER NOT NULL,
            taps INTEGER NOT NULL,
            installs INTEGER NOT NULL,
            spend REAL NOT NULL,
            ttr REAL,
            conversion_rate REAL,
            avg_cpt REAL,
            avg_cpi REAL,
            period_start REAL NOT NULL,
            period_end REAL NOT NULL,
            fetched_at REAL NOT NULL
        );
        CREATE INDEX ads_keyword_stats_app ON ads_keyword_stats (app_id, normalized, country_code);
        """,
        // 7: RevenueCat overview snapshots per project (a project can hold several apps), at most one per project and day.
        """
        CREATE TABLE revenue_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id TEXT NOT NULL,
            project_name TEXT NOT NULL,
            bundle_ids TEXT NOT NULL,
            app_names TEXT NOT NULL,
            mrr REAL NOT NULL,
            active_subscriptions INTEGER NOT NULL,
            revenue_28d REAL NOT NULL,
            new_customers_28d INTEGER NOT NULL,
            active_trials INTEGER NOT NULL,
            active_users_28d INTEGER NOT NULL,
            fetched_at REAL NOT NULL
        );
        CREATE INDEX revenue_snapshots_project ON revenue_snapshots (project_id, fetched_at);
        """,
        // 8: metadata per locale (what Apple holds, and the draft being written) and the legal footer settings per app.
        """
        CREATE TABLE metadata_baselines (
            app_id INTEGER NOT NULL REFERENCES apps(track_id) ON DELETE CASCADE,
            locale TEXT NOT NULL,
            name TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            keywords TEXT NOT NULL,
            promotional_text TEXT NOT NULL,
            description TEXT NOT NULL,
            whats_new TEXT NOT NULL,
            source TEXT NOT NULL,
            app_info_localization_id TEXT,
            version_localization_id TEXT,
            version_string TEXT,
            version_state TEXT,
            fetched_at REAL NOT NULL,
            PRIMARY KEY (app_id, locale)
        );
        CREATE TABLE metadata_drafts (
            app_id INTEGER NOT NULL REFERENCES apps(track_id) ON DELETE CASCADE,
            locale TEXT NOT NULL,
            name TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            keywords TEXT NOT NULL,
            promotional_text TEXT NOT NULL,
            description TEXT NOT NULL,
            whats_new TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (app_id, locale)
        );
        ALTER TABLE apps ADD COLUMN legal_footer_enabled INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE apps ADD COLUMN eula_url TEXT NOT NULL DEFAULT '';
        ALTER TABLE apps ADD COLUMN privacy_url TEXT NOT NULL DEFAULT '';
        ALTER TABLE apps ADD COLUMN legal_note TEXT NOT NULL DEFAULT '';
        """,
    ]

    /// Opens or creates the data file at `url`, creating its folder, and brings the schema up to date.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(path: url.path)
    }

    /// A private database that lives as long as the store (tests, dry runs).
    public static func inMemory() throws -> Store { try Store(path: ":memory:") }

    private init(path: String) throws {
        let db = try Database(path: path)
        try Self.migrate(db)
        self.db = db
    }

    static func migrate(_ db: Database) throws {
        let current = try db.userVersion
        guard current <= migrations.count else {
            throw EngineError.database("The data file was written by a newer version (schema \(current)); update ASO Workbench.")
        }
        for (index, sql) in migrations.enumerated().dropFirst(current) {
            try db.transaction {
                try db.execute(sql)
                try db.setUserVersion(index + 1)
            }
        }
    }

    public var schemaVersion: Int {
        get throws { try db.userVersion }
    }

    // MARK: Apps

    /// Inserts the app or refreshes its public details. The creation date and the chosen Apple Ads genre of an existing
    /// app are kept.
    public func upsertApp(_ app: AppRecord) throws {
        try db.query("""
            INSERT INTO apps (track_id, bundle_id, name, seller_name, icon_url, primary_genre, store_version, created_at, ads_genre)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (track_id) DO UPDATE SET bundle_id = excluded.bundle_id, name = excluded.name,
                seller_name = excluded.seller_name, icon_url = excluded.icon_url, primary_genre = excluded.primary_genre,
                store_version = excluded.store_version
            """, [.int(app.trackID), SQLValue(app.bundleID), .text(app.name), .text(app.sellerName), SQLValue(app.iconURL),
                  SQLValue(app.primaryGenre), SQLValue(app.storeVersion), SQLValue(app.createdAt), SQLValue(app.adsGenre)])
    }

    /// Sets the Apple Ads genre (nil: search every genre). False when the app is not tracked.
    @discardableResult
    public func setAdsGenre(trackID: Int, genre: String?) throws -> Bool {
        try db.query("UPDATE apps SET ads_genre = ? WHERE track_id = ?", [SQLValue(genre), .int(trackID)])
        return db.changes > 0
    }

    public func apps() throws -> [AppRecord] {
        try db.rows("SELECT \(Self.appColumns) FROM apps ORDER BY name COLLATE NOCASE", map: Self.app)
    }

    public func app(trackID: Int) throws -> AppRecord? {
        try db.rows("SELECT \(Self.appColumns) FROM apps WHERE track_id = ?", [.int(trackID)], map: Self.app).first
    }

    /// Removes the app with its markets, keywords and observations. False when it was not tracked.
    @discardableResult
    public func removeApp(trackID: Int) throws -> Bool {
        try db.query("DELETE FROM apps WHERE track_id = ?", [.int(trackID)])
        return db.changes > 0
    }

    // MARK: Markets

    /// The market for an app, country and device, created on first use.
    public func market(appID: Int, countryCode: String, device: DeviceContext) throws -> MarketRecord {
        let country = countryCode.uppercased()
        try db.query("INSERT OR IGNORE INTO markets (app_id, country_code, device, created_at) VALUES (?, ?, ?, ?)",
                     [.int(appID), .text(country), .text(device.rawValue), SQLValue(Date())])
        guard let market = try db.rows("SELECT \(Self.marketColumns) FROM markets WHERE app_id = ? AND country_code = ? AND device = ?",
                                        [.int(appID), .text(country), .text(device.rawValue)], map: Self.market).first else {
            throw EngineError.database("The market \(country) Â· \(device.rawValue) could not be created.")
        }
        return market
    }

    /// Removes a market with its keywords and measurements. False when there was none.
    @discardableResult
    public func removeMarket(appID: Int, countryCode: String, device: DeviceContext) throws -> Bool {
        try db.query("DELETE FROM markets WHERE app_id = ? AND country_code = ? AND device = ?",
                     [.int(appID), .text(countryCode.uppercased()), .text(device.rawValue)])
        return db.changes > 0
    }

    /// An app's markets with their keyword count and newest measurement of any outcome.
    public func marketSummaries(appID: Int) throws -> [(market: MarketRecord, keywords: Int, lastMeasuredAt: Date?)] {
        try db.rows("""
            SELECT m.id, m.app_id, m.country_code, m.device, m.created_at, COUNT(DISTINCT k.id), MAX(o.fetched_at)
            FROM markets m
            LEFT JOIN keywords k ON k.market_id = m.id
            LEFT JOIN rank_observations o ON o.keyword_id = k.id
            WHERE m.app_id = ?
            GROUP BY m.id
            ORDER BY m.country_code, m.device
            """, [.int(appID)]) { row in (Self.market(row), row.int(5), row.isNull(6) ? nil : row.date(6)) }
    }

    /// Every market that has keywords, with its newest measurement of any outcome (nil when never measured).
    public func marketsWithKeywords() throws -> [(market: MarketRecord, lastMeasuredAt: Date?)] {
        try db.rows("""
            SELECT m.id, m.app_id, m.country_code, m.device, m.created_at, MAX(o.fetched_at)
            FROM markets m
            JOIN keywords k ON k.market_id = m.id
            LEFT JOIN rank_observations o ON o.keyword_id = k.id
            GROUP BY m.id
            ORDER BY m.app_id, m.country_code, m.device
            """) { row in (Self.market(row), row.isNull(5) ? nil : row.date(5)) }
    }

    public func markets(appID: Int) throws -> [MarketRecord] {
        try db.rows("SELECT \(Self.marketColumns) FROM markets WHERE app_id = ? ORDER BY country_code, device", [.int(appID)], map: Self.market)
    }

    // MARK: Keywords

    /// Adds keywords to a market, skipping blanks and ones it already tracks (compared normalized).
    /// Returns the added records and the texts that were already there.
    public func addKeywords(_ texts: [String], marketID: Int) throws -> (added: [KeywordRecord], existing: [String]) {
        try db.transaction {
            var added: [KeywordRecord] = []
            var existing: [String] = []
            var seen = Set<String>()
            for raw in texts {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = KeywordText.normalize(text)
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                try db.query("INSERT OR IGNORE INTO keywords (market_id, text, normalized, created_at) VALUES (?, ?, ?, ?)",
                             [.int(marketID), .text(text), .text(normalized), SQLValue(Date())])
                if db.changes == 0 {
                    existing.append(text)
                } else if let record = try db.rows("SELECT \(Self.keywordColumns) FROM keywords WHERE id = ?", [.int(db.lastInsertID)],
                                                   map: Self.keyword).first {
                    added.append(record)
                }
            }
            return (added, existing)
        }
    }

    public func keywords(marketID: Int) throws -> [KeywordRecord] {
        try db.rows("SELECT \(Self.keywordColumns) FROM keywords WHERE market_id = ? ORDER BY normalized", [.int(marketID)], map: Self.keyword)
    }

    /// The keyword with this text (compared normalized) in the market, if tracked.
    public func keyword(_ text: String, marketID: Int) throws -> KeywordRecord? {
        try db.rows("SELECT \(Self.keywordColumns) FROM keywords WHERE market_id = ? AND normalized = ?",
                    [.int(marketID), .text(KeywordText.normalize(text))], map: Self.keyword).first
    }

    /// Replaces the keyword's note (empty clears it). False when the keyword does not exist.
    @discardableResult
    public func setNote(_ note: String, keywordID: Int) throws -> Bool {
        try db.query("UPDATE keywords SET note = ? WHERE id = ?", [.text(note), .int(keywordID)])
        return db.changes > 0
    }

    /// Removes keywords (matched normalized) with their observations; returns how many were removed.
    @discardableResult
    public func removeKeywords(_ texts: [String], marketID: Int) throws -> Int {
        try db.transaction {
            var removed = 0
            for text in texts {
                try db.query("DELETE FROM keywords WHERE market_id = ? AND normalized = ?", [.int(marketID), .text(KeywordText.normalize(text))])
                removed += db.changes
            }
            return removed
        }
    }

    // MARK: Observations

    /// Stores one measurement, failures included. Keeps the first `keepResults` results; the competition signals are
    /// computed from all of them, as in the macOS app.
    @discardableResult
    public func addObservation(_ sample: RankSample, keywordID: Int, keepResults: Int = 50) throws -> Int {
        let columns = StoredOutcome.columns(sample.outcome)
        let results = try JSONEncoder().encode(Array(sample.results.prefix(keepResults)))
        let signals = sample.results.isEmpty ? nil : try JSONEncoder().encode(CompetitionSignals(results: sample.results, term: sample.keyword))
        try db.query("""
            INSERT INTO rank_observations (keyword_id, fetched_at, provider, device, outcome_kind, position, observed_count,
                failure_reason, results, signals)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.int(keywordID), SQLValue(sample.fetchedAt), .text(sample.provider.rawValue), .text(sample.device.rawValue),
                  .text(columns.kind), SQLValue(columns.position), .int(columns.observedCount), SQLValue(columns.failureReason),
                  .blob(results), SQLValue(signals)])
        return db.lastInsertID
    }

    public func observations(keywordID: Int) throws -> [RankObservationRecord] {
        try db.rows("""
            SELECT id, keyword_id, fetched_at, provider, device, outcome_kind, position, observed_count, failure_reason, results, signals
            FROM rank_observations WHERE keyword_id = ? ORDER BY fetched_at, id
            """, [.int(keywordID)]) { row in
            RankObservationRecord(id: row.int(0), keywordID: row.int(1), fetchedAt: row.date(2), provider: ProviderID(rawValue: row.text(3)),
                                  device: DeviceContext(rawValue: row.text(4)) ?? .iPhone,
                                  outcome: StoredOutcome.outcome(kind: row.text(5), position: row.optionalInt(6), observedCount: row.int(7),
                                                                 failureReason: row.optionalText(8)),
                                  resultsData: row.blob(9), signalsData: row.optionalBlob(10))
        }
    }

    // MARK: Popularity

    public func addPopularity(_ reading: PopularityReading, keywordID: Int) throws {
        try db.query("""
            INSERT INTO popularity_readings (keyword_id, fetched_at, country_code, genre, period_start, period_end, popularity, popularity_1to5,
                popularity_in_genre, rank_in_genre, source, upper_bound, any_genre)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.int(keywordID), SQLValue(reading.fetchedAt), .text(reading.country), SQLValue(reading.genre), SQLValue(reading.periodStart),
                  SQLValue(reading.periodEnd), SQLValue(reading.popularity), SQLValue(reading.popularity1to5), SQLValue(reading.popularityInGenre),
                  SQLValue(reading.rankInGenre), .text(reading.source), SQLValue(reading.upperBound), .int(reading.anyGenre ? 1 : 0)])
    }

    /// The keyword's newest popularity reading.
    public func latestPopularity(keywordID: Int) throws -> PopularityReading? {
        try db.rows("""
            SELECT fetched_at, country_code, genre, period_start, period_end, popularity, popularity_1to5, popularity_in_genre, rank_in_genre,
                source, upper_bound, any_genre
            FROM popularity_readings WHERE keyword_id = ? ORDER BY fetched_at DESC, id DESC LIMIT 1
            """, [.int(keywordID)]) { row in
            PopularityReading(fetchedAt: row.date(0), country: row.text(1), genre: row.optionalText(2), periodStart: row.date(3), periodEnd: row.date(4),
                              popularity: row.optionalInt(5), popularity1to5: row.optionalInt(6), popularityInGenre: row.optionalInt(7),
                              rankInGenre: row.optionalInt(8), source: row.text(9), upperBound: row.optionalInt(10), anyGenre: row.int(11) == 1)
        }.first
    }

    // MARK: Apple Ads campaigns

    /// Replaces one campaign's rows for the app with a fresh sync, in one transaction.
    public func replaceAdsStats(_ stats: [AdsKeywordStatRecord], campaignID: Int, appID: Int) throws {
        try db.transaction {
            try db.query("DELETE FROM ads_keyword_stats WHERE app_id = ? AND campaign_id = ?", [.int(appID), .int(campaignID)])
            for s in stats {
                try db.query("""
                    INSERT INTO ads_keyword_stats (app_id, campaign_id, campaign_name, ad_group_name, keyword_id, keyword, normalized, match_type,
                        status, country_code, bid, currency, impressions, taps, installs, spend, ttr, conversion_rate, avg_cpt, avg_cpi,
                        period_start, period_end, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.int(appID), .int(campaignID), .text(s.campaignName), .text(s.adGroupName), .int(s.keywordID), .text(s.keyword),
                          .text(KeywordText.normalize(s.keyword)), .text(s.matchType), .text(s.status), .text(s.country), SQLValue(s.bid),
                          .text(s.currency), .int(s.impressions), .int(s.taps), .int(s.installs), SQLValue(s.spend), SQLValue(s.ttr),
                          SQLValue(s.conversionRate), SQLValue(s.avgCPT), SQLValue(s.avgCPI), SQLValue(s.periodStart), SQLValue(s.periodEnd),
                          SQLValue(s.fetchedAt)])
            }
        }
    }

    /// The app's stored campaign rows, biggest spend first.
    public func adsStats(appID: Int) throws -> [AdsKeywordStatRecord] {
        try db.rows("""
            SELECT campaign_id, campaign_name, ad_group_name, keyword_id, keyword, match_type, status, country_code, bid, currency, impressions,
                taps, installs, spend, ttr, conversion_rate, avg_cpt, avg_cpi, period_start, period_end, fetched_at
            FROM ads_keyword_stats WHERE app_id = ? ORDER BY spend DESC, impressions DESC, id
            """, [.int(appID)]) { row in
            AdsKeywordStatRecord(campaignID: row.int(0), campaignName: row.text(1), adGroupName: row.text(2), keywordID: row.int(3), keyword: row.text(4),
                                 matchType: row.text(5), status: row.text(6), country: row.text(7), bid: row.optionalDouble(8), currency: row.text(9),
                                 impressions: row.int(10), taps: row.int(11), installs: row.int(12), spend: row.double(13), ttr: row.optionalDouble(14),
                                 conversionRate: row.optionalDouble(15), avgCPT: row.optionalDouble(16), avgCPI: row.optionalDouble(17),
                                 periodStart: row.date(18), periodEnd: row.date(19), fetchedAt: row.date(20))
        }
    }

    // MARK: Revenue

    /// Stores a project's snapshot, replacing one already stored since `dayStart`, in one transaction.
    public func replaceRevenueSnapshot(_ snapshot: RevenueSnapshotRecord, since dayStart: Date) throws {
        try db.transaction {
            try db.query("DELETE FROM revenue_snapshots WHERE project_id = ? AND fetched_at >= ?", [.text(snapshot.projectID), SQLValue(dayStart)])
            try db.query("""
                INSERT INTO revenue_snapshots (project_id, project_name, bundle_ids, app_names, mrr, active_subscriptions, revenue_28d,
                    new_customers_28d, active_trials, active_users_28d, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(snapshot.projectID), .text(snapshot.projectName), .text(snapshot.bundleIDs.joined(separator: "|")),
                      .text(snapshot.appNames.joined(separator: "|")), SQLValue(snapshot.mrr), .int(snapshot.activeSubscriptions),
                      SQLValue(snapshot.revenue28d), .int(snapshot.newCustomers28d), .int(snapshot.activeTrials), .int(snapshot.activeUsers28d),
                      SQLValue(snapshot.fetchedAt)])
        }
    }

    /// Every stored snapshot, newest first.
    public func revenueSnapshots() throws -> [RevenueSnapshotRecord] {
        try db.rows("""
            SELECT project_id, project_name, bundle_ids, app_names, mrr, active_subscriptions, revenue_28d, new_customers_28d, active_trials,
                active_users_28d, fetched_at
            FROM revenue_snapshots ORDER BY fetched_at DESC, id DESC
            """) { row in
            RevenueSnapshotRecord(projectID: row.text(0), projectName: row.text(1), bundleIDs: Self.list(row.text(2)), appNames: Self.list(row.text(3)),
                                  mrr: row.double(4), activeSubscriptions: row.int(5), revenue28d: row.double(6), newCustomers28d: row.int(7),
                                  activeTrials: row.int(8), activeUsers28d: row.int(9), fetchedAt: row.date(10))
        }
    }

    private static func list(_ joined: String) -> [String] { joined.split(separator: "|").map(String.init) }

    // MARK: Metadata

    private static let fieldColumns = "name, subtitle, keywords, promotional_text, description, whats_new"

    private static func fieldValues(_ f: MetadataFields) -> [SQLValue] {
        [.text(f.name), .text(f.subtitle), .text(f.keywords), .text(f.promotionalText), .text(f.description), .text(f.whatsNew)]
    }

    private static func fields(_ row: Row, from first: Int32) -> MetadataFields {
        MetadataFields(name: row.text(first), subtitle: row.text(first + 1), keywords: row.text(first + 2), promotionalText: row.text(first + 3),
                       description: row.text(first + 4), whatsNew: row.text(first + 5))
    }

    /// Stores the baseline of one locale, replacing the one before.
    public func replaceBaseline(_ baseline: MetadataBaselineRecord, appID: Int) throws {
        try db.query("""
            INSERT OR REPLACE INTO metadata_baselines (app_id, locale, \(Self.fieldColumns), source, app_info_localization_id,
                version_localization_id, version_string, version_state, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.int(appID), .text(baseline.locale)] + Self.fieldValues(baseline.fields)
                + [.text(baseline.source), SQLValue(baseline.appInfoLocalizationID), SQLValue(baseline.versionLocalizationID),
                   SQLValue(baseline.versionString), SQLValue(baseline.versionState), SQLValue(baseline.fetchedAt)])
    }

    public func baselines(appID: Int) throws -> [MetadataBaselineRecord] {
        try db.rows("""
            SELECT locale, \(Self.fieldColumns), source, app_info_localization_id, version_localization_id, version_string, version_state, fetched_at
            FROM metadata_baselines WHERE app_id = ? ORDER BY locale
            """, [.int(appID)]) { row in
            MetadataBaselineRecord(locale: row.text(0), fields: Self.fields(row, from: 1), source: row.text(7), appInfoLocalizationID: row.optionalText(8),
                                   versionLocalizationID: row.optionalText(9), versionString: row.optionalText(10), versionState: row.optionalText(11),
                                   fetchedAt: row.date(12))
        }
    }

    /// Stores the draft of one locale, replacing the one before.
    public func replaceDraft(_ draft: MetadataDraftRecord, appID: Int) throws {
        try db.query("INSERT OR REPLACE INTO metadata_drafts (app_id, locale, \(Self.fieldColumns), updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                     [.int(appID), .text(draft.locale)] + Self.fieldValues(draft.fields) + [SQLValue(draft.updatedAt)])
    }

    /// Drops the draft of one locale. False when there was none.
    @discardableResult
    public func removeDraft(appID: Int, locale: String) throws -> Bool {
        try db.query("DELETE FROM metadata_drafts WHERE app_id = ? AND locale = ?", [.int(appID), .text(locale)])
        return db.changes > 0
    }

    public func drafts(appID: Int) throws -> [MetadataDraftRecord] {
        try db.rows("SELECT locale, \(Self.fieldColumns), updated_at FROM metadata_drafts WHERE app_id = ? ORDER BY locale", [.int(appID)]) { row in
            MetadataDraftRecord(locale: row.text(0), fields: Self.fields(row, from: 1), updatedAt: row.date(7))
        }
    }

    public func legalFooter(appID: Int) throws -> LegalFooterSettings? {
        try db.rows("SELECT legal_footer_enabled, eula_url, privacy_url, legal_note FROM apps WHERE track_id = ?", [.int(appID)]) { row in
            LegalFooterSettings(enabled: row.int(0) != 0, eulaURL: row.text(1), privacyURL: row.text(2), note: row.text(3))
        }.first
    }

    public func setLegalFooter(_ settings: LegalFooterSettings, appID: Int) throws {
        try db.query("UPDATE apps SET legal_footer_enabled = ?, eula_url = ?, privacy_url = ?, legal_note = ? WHERE track_id = ?",
                     [.int(settings.enabled ? 1 : 0), .text(settings.eulaURL), .text(settings.privacyURL), .text(settings.note), .int(appID)])
    }

    // MARK: Ratings

    public func addRating(_ reading: RatingReading, appID: Int) throws {
        try db.query("INSERT INTO ratings (app_id, country_code, count, average, fetched_at) VALUES (?, ?, ?, ?, ?)",
                     [.int(appID), .text(reading.countryCode), .int(reading.count), SQLValue(reading.average), SQLValue(reading.fetchedAt)])
    }

    /// The newest reading for the app in one storefront.
    public func latestRating(appID: Int, countryCode: String) throws -> RatingReading? {
        try db.rows("""
            SELECT country_code, count, average, fetched_at FROM ratings WHERE app_id = ? AND country_code = ?
            ORDER BY fetched_at DESC, id DESC LIMIT 1
            """, [.int(appID), .text(countryCode)], map: Self.rating).first
    }

    public func ratings(appID: Int) throws -> [RatingReading] {
        try db.rows("SELECT country_code, count, average, fetched_at FROM ratings WHERE app_id = ? ORDER BY fetched_at, id", [.int(appID)],
                    map: Self.rating)
    }

    // MARK: Reviews

    /// Stores one check's reviews: the previous check's "new" marks are cleared, and reviews not seen before are added.
    /// They are marked new unless the app had no stored reviews: its first check is history, not news. Returns how
    /// many were added.
    @discardableResult
    public func recordReviews(_ reviews: [CustomerReview], appID: Int, fetchedAt: Date) throws -> Int {
        try db.transaction {
            let hadReviews = try db.rows("SELECT EXISTS (SELECT 1 FROM reviews WHERE app_id = ?)", [.int(appID)]) { $0.int(0) == 1 }.first ?? false
            try db.query("UPDATE reviews SET is_new = 0 WHERE app_id = ? AND is_new = 1", [.int(appID)])
            var added = 0
            for review in reviews {
                try db.query("""
                    INSERT OR IGNORE INTO reviews (app_id, review_id, country_code, title, body, rating, author, version, date, fetched_at, is_new)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.int(appID), .text(StoredReview.key(review)), .text(review.countryCode), .text(review.title), .text(review.body),
                          .int(review.rating), .text(review.author), SQLValue(review.version), review.date.map { SQLValue($0) } ?? .null,
                          SQLValue(fetchedAt), .int(hadReviews ? 1 : 0)])
                added += db.changes
            }
            return added
        }
    }

    /// The app's stored reviews, newest first (by review date, else by when they were read).
    public func reviews(appID: Int) throws -> [StoredReview] {
        try db.rows("""
            SELECT review_id, country_code, title, body, rating, author, version, date, fetched_at, is_new FROM reviews WHERE app_id = ?
            ORDER BY COALESCE(date, fetched_at) DESC, review_id
            """, [.int(appID)]) { row in
            StoredReview(id: row.text(0), country: row.text(1), title: row.text(2), body: row.text(3), rating: row.int(4), author: row.text(5),
                         version: row.optionalText(6), date: row.isNull(7) ? nil : row.date(7), fetchedAt: row.date(8), isNew: row.int(9) == 1)
        }
    }

    // MARK: Markers

    /// Records the release of `version` unless it was already looked at: the first look at an app records its current
    /// release, a new version records another, and a version whose marker was removed is not added back.
    public func recordRelease(version: String, date: Date, countryCode: String, appID: Int) throws -> MarkerRecord? {
        try db.transaction {
            let checked: [String?] = try db.rows("SELECT release_checked_version FROM apps WHERE track_id = ?", [.int(appID)]) { $0.optionalText(0) }
            guard let last = checked.first, last != version else { return nil }
            try db.query("UPDATE apps SET release_checked_version = ?, store_version = ? WHERE track_id = ?",
                         [.text(version), .text(version), .int(appID)])
            let known = try db.rows("SELECT EXISTS (SELECT 1 FROM markers WHERE app_id = ? AND kind = 'release' AND version = ?)",
                                    [.int(appID), .text(version)]) { $0.int(0) == 1 }.first ?? false
            guard !known else { return nil }
            return try addMarker(appID: appID, date: date, kind: "release", title: "v\(version)", version: version, countryCode: countryCode)
        }
    }

    @discardableResult
    public func addMarker(appID: Int, date: Date, kind: String, title: String, version: String? = nil, countryCode: String? = nil) throws -> MarkerRecord {
        try db.query("INSERT INTO markers (app_id, date, kind, title, version, country_code) VALUES (?, ?, ?, ?, ?, ?)",
                     [.int(appID), SQLValue(date), .text(kind), .text(title), SQLValue(version), SQLValue(countryCode)])
        return MarkerRecord(id: db.lastInsertID, date: date, kind: kind, title: title, version: version, country: countryCode)
    }

    /// The app's markers, oldest first.
    public func markers(appID: Int) throws -> [MarkerRecord] {
        try db.rows("SELECT id, date, kind, title, version, country_code FROM markers WHERE app_id = ? ORDER BY date, id", [.int(appID)]) { row in
            MarkerRecord(id: row.int(0), date: row.date(1), kind: row.text(2), title: row.text(3), version: row.optionalText(4), country: row.optionalText(5))
        }
    }

    /// False when the app has no marker with this id.
    @discardableResult
    public func removeMarker(id: Int, appID: Int) throws -> Bool {
        try db.query("DELETE FROM markers WHERE id = ? AND app_id = ?", [.int(id), .int(appID)])
        return db.changes > 0
    }

    // MARK: Row mapping

    private static func rating(_ row: Row) -> RatingReading {
        RatingReading(countryCode: row.text(0), count: row.int(1), average: row.optionalDouble(2), fetchedAt: row.date(3))
    }

    private static let appColumns = "track_id, bundle_id, name, seller_name, icon_url, primary_genre, store_version, created_at, ads_genre"
    private static func app(_ row: Row) -> AppRecord {
        AppRecord(trackID: row.int(0), bundleID: row.optionalText(1), name: row.text(2), sellerName: row.text(3), iconURL: row.optionalText(4),
                  primaryGenre: row.optionalText(5), storeVersion: row.optionalText(6), createdAt: row.date(7), adsGenre: row.optionalText(8))
    }

    private static let marketColumns = "id, app_id, country_code, device, created_at"
    private static func market(_ row: Row) -> MarketRecord {
        MarketRecord(id: row.int(0), appID: row.int(1), countryCode: row.text(2), device: DeviceContext(rawValue: row.text(3)) ?? .iPhone,
                     createdAt: row.date(4))
    }

    private static let keywordColumns = "id, market_id, text, normalized, created_at, note, brand_probability, fit_probability, navigational"
    private static func keyword(_ row: Row) -> KeywordRecord {
        KeywordRecord(id: row.int(0), marketID: row.int(1), text: row.text(2), normalized: row.text(3), createdAt: row.date(4), note: row.text(5),
                      brandProbability: row.optionalDouble(6), fitProbability: row.optionalDouble(7), navigational: row.optionalDouble(8))
    }
}
