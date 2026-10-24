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
            throw EngineError.database("The market \(country) · \(device.rawValue) could not be created.")
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

    // MARK: Row mapping

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
