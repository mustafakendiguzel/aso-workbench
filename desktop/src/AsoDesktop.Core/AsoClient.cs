using System.Globalization;
using System.Text.Json;

namespace AsoDesktop.Core;

/// <summary>
/// The aso command as typed calls. Every call runs one <c>aso … --json</c> and parses its stdout; all numbers and
/// verdicts come from the engine, none are computed here.
/// </summary>
public sealed class AsoClient(IAsoCli cli)
{
    public Task<EngineInfo> EngineInfoAsync(CancellationToken ct = default) => RunAsync<EngineInfo>(["--version"], ct);

    public async Task<string> VersionAsync(CancellationToken ct = default) => (await EngineInfoAsync(ct).ConfigureAwait(false)).Version;

    public Task<IReadOnlyList<AppRecord>> ListAppsAsync(CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<AppRecord>>(["app", "list"], ct);

    public Task<AppRecord> AddAppAsync(string reference, string? country, CancellationToken ct = default) =>
        RunAsync<AppRecord>(["app", "add", reference, .. Option("country", country)], ct);

    /// <summary>Tracks the app with one market per country for <paramref name="device"/>.</summary>
    public Task<AppRecord> AddAppAsync(string reference, string? lookupCountry, IReadOnlyCollection<string> markets, string device,
                                       CancellationToken ct = default) =>
        RunAsync<AppRecord>(["app", "add", reference, .. Option("country", lookupCountry), .. Option("markets", string.Join(',', markets)),
                             "--device", device], ct);

    /// <summary>Search by name, App Store link or ID; nothing is stored.</summary>
    public Task<IReadOnlyList<SearchResultApp>> FindAppsAsync(string query, string country, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<SearchResultApp>>(["app", "search", "--country", country, "--", query], ct);

    /// <param name="genre">An Apple Ads genre ID, or null for every genre.</param>
    public Task<AppRecord> SetAdsGenreAsync(long appId, string? genre, CancellationToken ct = default) =>
        RunAsync<AppRecord>(["app", "genre", Id(appId), genre ?? "any"], ct);

    public Task<IReadOnlyList<MarketSummary>> MarketsAsync(long appId, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<MarketSummary>>(["market", "list", Id(appId)], ct);

    public Task<MarketSummary> AddMarketAsync(long appId, string country, string device, CancellationToken ct = default) =>
        RunAsync<MarketSummary>(["market", "add", Id(appId), "--country", country, "--device", device], ct);

    public async Task RemoveMarketAsync(long appId, string country, string device, CancellationToken ct = default) =>
        await RunAsync<JsonElement>(["market", "remove", Id(appId), "--country", country, "--device", device], ct).ConfigureAwait(false);

    public Task<IReadOnlyList<StorefrontInfo>> StorefrontsAsync(CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<StorefrontInfo>>(["storefronts"], ct);

    public Task<IReadOnlyList<GenreInfo>> GenresAsync(CancellationToken ct = default) => RunAsync<IReadOnlyList<GenreInfo>>(["genres"], ct);

    public Task<KeywordDetail> KeywordDetailAsync(long appId, string keyword, string country, string device, string delta,
                                                  CancellationToken ct = default) =>
        RunAsync<KeywordDetail>(["keywords", "show", Id(appId), "--country", country, "--device", device, "--delta", delta, "--", keyword], ct);

    /// <summary>Replaces the keyword's note; an empty note clears it.</summary>
    public async Task SetNoteAsync(long appId, string keyword, string country, string device, string note, CancellationToken ct = default) =>
        await RunAsync<JsonElement>(["keywords", "note", Id(appId), "--country", country, "--device", device, "--text", note, "--", keyword], ct)
            .ConfigureAwait(false);

    /// <summary>Measures only these keywords of the market.</summary>
    public Task<MeasureSummary> MeasureKeywordsAsync(long appId, string country, string device, IReadOnlyCollection<string> keywords,
                                                     IProgress<MeasureStep>? progress = null, CancellationToken ct = default) =>
        RunAsync<MeasureSummary>(["measure", Id(appId), "--country", country, "--device", device, "--keywords", string.Join(',', keywords)], ct,
                                 line => { if (ParseStep(line) is { } step) progress?.Report(step); });

    /// <summary>Apple Ads popularity for the market's keywords, or only <paramref name="keywords"/> when given.</summary>
    public Task<IReadOnlyList<PopularityRefresh>> PopularityAsync(long appId, string country, string device,
                                                                 IReadOnlyCollection<string>? keywords = null, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<PopularityRefresh>>(
            ["popularity", Id(appId), "--country", country, "--device", device,
             .. Option("keywords", keywords is { Count: > 0 } ? string.Join(',', keywords) : null)], ct);

    /// <summary>Reads every RevenueCat project the stored keys reach; one snapshot per project and day is kept.</summary>
    public Task<RevenueRefresh> RefreshRevenueAsync(CancellationToken ct = default) => RunAsync<RevenueRefresh>(["revenue", "refresh"], ct);

    public Task<RevenueReport> RevenueAsync(long appId, CancellationToken ct = default) => RunAsync<RevenueReport>(["revenue", "show", Id(appId)], ct);

    // MARK: Metadata (drafts stay on this computer)

    public Task<IReadOnlyList<LocaleInfo>> AllLocalesAsync(CancellationToken ct = default) => RunAsync<IReadOnlyList<LocaleInfo>>(["locales"], ct);

    public Task<IReadOnlyList<MetadataLocale>> MetadataLocalesAsync(long appId, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<MetadataLocale>>(["metadata", "locales", Id(appId)], ct);

    public Task<MetadataReport> MetadataAsync(long appId, string locale, CancellationToken ct = default) =>
        RunAsync<MetadataReport>(["metadata", "show", Id(appId), "--locale", locale], ct);

    /// <summary>Saves every field of the draft; the text goes through stdin, so long descriptions and line breaks arrive whole.</summary>
    public Task<MetadataReport> SaveDraftAsync(long appId, string locale, MetadataFields fields, CancellationToken ct = default) =>
        RunAsync<MetadataReport>(["metadata", "draft", Id(appId), "--locale", locale, "--stdin"], ct,
                                 standardInput: JsonSerializer.Serialize(fields, Json.Options));

    /// <summary>Records what is live on the App Store today, typed in.</summary>
    public Task<MetadataReport> SetBaselineAsync(long appId, string locale, MetadataFields fields, CancellationToken ct = default) =>
        RunAsync<MetadataReport>(["metadata", "baseline", Id(appId), "--locale", locale, "--stdin"], ct,
                                 standardInput: JsonSerializer.Serialize(fields, Json.Options));

    public Task<MetadataReport> ResetDraftAsync(long appId, string locale, CancellationToken ct = default) =>
        RunAsync<MetadataReport>(["metadata", "reset", Id(appId), "--locale", locale], ct);

    /// <summary>Saves the legal footer settings; empty URLs are sent as they are (an empty Terms of Use URL means Apple's standard EULA).</summary>
    public Task<LegalFooterSettings> SetLegalFooterAsync(long appId, LegalFooterSettings settings, CancellationToken ct = default) =>
        RunAsync<LegalFooterSettings>(["metadata", "legal", Id(appId), settings.Enabled ? "--on" : "--off", "--eula", settings.EulaUrl,
                                       "--privacy", settings.PrivacyUrl, "--note", settings.Note], ct);

    /// <param name="locale">One locale, or null for every locale worth writing.</param>
    public Task<MetadataBatch> InsertLegalFooterAsync(long appId, string? locale, CancellationToken ct = default) =>
        RunAsync<MetadataBatch>(["metadata", "footer", Id(appId), .. Option("locale", locale)], ct);

    public Task<MetadataBatch> FillEmptyWhatsNewAsync(long appId, CancellationToken ct = default) =>
        RunAsync<MetadataBatch>(["metadata", "fill-whats-new", Id(appId)], ct);

    // MARK: Publishing (App Store Connect; nothing is written without the confirming --yes)

    /// <summary>Reads every locale from App Store Connect as the baseline; nothing is written to Apple.</summary>
    public Task<MetadataPull> PullMetadataAsync(long appId, CancellationToken ct = default) =>
        RunAsync<MetadataPull>(["metadata", "pull", Id(appId)], ct);

    public Task<IReadOnlyList<AscVersion>> AscVersionsAsync(long appId, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<AscVersion>>(["metadata", "versions", Id(appId)], ct);

    /// <summary>Creates the next version on App Store Connect.</summary>
    public Task<AscVersion> CreateVersionAsync(long appId, string version, CancellationToken ct = default) =>
        RunAsync<AscVersion>(["metadata", "create-version", Id(appId), version, "--yes"], ct);

    /// <summary>What applying the locale would send; writes nothing.</summary>
    public Task<PublishPlan> PublishPlanAsync(long appId, string locale, bool createMissing, string? copyScreenshotsFrom,
                                              CancellationToken ct = default) =>
        RunAsync<PublishPlan>(["metadata", "plan", Id(appId), "--locale", locale, .. Flag("create-missing", createMissing),
                               .. Option("copy-screenshots-from", copyScreenshotsFrom)], ct);

    /// <summary>Plans for every locale with a draft, missing ones to be created; writes nothing.</summary>
    public Task<IReadOnlyList<PublishPlan>> PublishPlansAsync(long appId, string? copyScreenshotsFrom, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<PublishPlan>>(["metadata", "plan", Id(appId), "--all", .. Option("copy-screenshots-from", copyScreenshotsFrom)], ct);

    /// <summary>Writes the locale's draft to App Store Connect and re-reads it. A refused or failed write is a result, not an exception.</summary>
    public Task<PublishResult> PublishAsync(long appId, string locale, bool createMissing, string? copyScreenshotsFrom, CancellationToken ct = default) =>
        RunWithResultAsync<PublishResult>(["metadata", "apply", Id(appId), "--locale", locale, .. Flag("create-missing", createMissing),
                                           .. Option("copy-screenshots-from", copyScreenshotsFrom), "--yes"], ct);

    /// <summary>Writes each locale in turn, creating the ones App Store Connect does not have.</summary>
    public Task<IReadOnlyList<PublishResult>> PublishAllAsync(long appId, IReadOnlyCollection<string> locales, string? copyScreenshotsFrom,
                                                              CancellationToken ct = default) =>
        RunWithResultAsync<IReadOnlyList<PublishResult>>(["metadata", "apply-all", Id(appId), "--locales", string.Join(',', locales),
                                                          .. Option("copy-screenshots-from", copyScreenshotsFrom), "--yes"], ct);

    public Task<IReadOnlyList<ChangeLogEntry>> ChangeLogAsync(long appId, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<ChangeLogEntry>>(["metadata", "log", Id(appId)], ct);

    /// <summary>Reads the last <paramref name="days"/> of every campaign that promotes a tracked app.</summary>
    public Task<AdsSync> SyncAdsAsync(int days = 30, CancellationToken ct = default) =>
        RunAsync<AdsSync>(["ads", "sync", "--days", days.ToString(CultureInfo.InvariantCulture)], ct);

    public Task<AdsReport> AdsAsync(long appId, CancellationToken ct = default) => RunAsync<AdsReport>(["ads", "list", Id(appId)], ct);

    /// <summary>Keyword candidates for the market, from a competitor's listing when <paramref name="competitorId"/> is given.</summary>
    public Task<DiscoveryReport> DiscoverAsync(long appId, string country, string device, long? competitorId = null,
                                               IReadOnlyCollection<string>? seeds = null, int difficultyLimit = 25,
                                               IProgress<DiscoveryStep>? progress = null, CancellationToken ct = default) =>
        RunAsync<DiscoveryReport>(
            ["discover", Id(appId), "--country", country, "--device", device,
             .. Option("competitor", competitorId is { } id ? Id(id) : null),
             .. Option("seeds", seeds is { Count: > 0 } ? string.Join(',', seeds) : null),
             "--difficulty", difficultyLimit.ToString(CultureInfo.InvariantCulture)], ct,
            line => { if (Parse<DiscoveryStep>(line) is { } step) progress?.Report(step); });

    /// <summary>The market's keywords in the macOS app's CSV format.</summary>
    public async Task<string> KeywordsCsvAsync(long appId, string country, string device, string delta, CancellationToken ct = default)
    {
        var result = await cli.RunAsync(["keywords", "list", Id(appId), "--country", country, "--device", device, "--delta", delta, "--csv"], null, null, ct)
            .ConfigureAwait(false);
        if (result.ExitCode != 0) throw AsoCliException.From(result);
        return result.Output;
    }

    /// <summary>Measures one market's keywords.</summary>
    public Task<MeasureSummary> MeasureMarketAsync(long appId, string country, string device, IProgress<MeasureStep>? progress = null,
                                                   CancellationToken ct = default) =>
        MeasureAsync(appId, country, device, progress, ct);

    public async Task RemoveAppAsync(long appId, CancellationToken ct = default) =>
        await RunAsync<JsonElement>(["app", "remove", Id(appId)], ct).ConfigureAwait(false);

    public Task<IReadOnlyList<KeywordReportRow>> ListKeywordsAsync(long appId, string? country = null, string? device = null,
                                                                   string delta = "previous", CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<KeywordReportRow>>(
            ["keywords", "list", Id(appId), .. Option("country", country), .. Option("device", device), "--delta", delta], ct);

    public Task<AddedKeywords> AddKeywordsAsync(long appId, IEnumerable<string> keywords, string country, string device,
                                                CancellationToken ct = default) =>
        RunAsync<AddedKeywords>(["keywords", "add", Id(appId), "--country", country, "--device", device, "--", .. keywords], ct);

    public async Task<int> RemoveKeywordsAsync(long appId, IEnumerable<string> keywords, string country, string device,
                                               CancellationToken ct = default)
    {
        var result = await RunAsync<JsonElement>(
            ["keywords", "remove", Id(appId), "--country", country, "--device", device, "--", .. keywords], ct).ConfigureAwait(false);
        return result.GetProperty("removed").GetInt32();
    }

    /// <summary>Fresh rank checks; <paramref name="progress"/> gets one step per keyword as aso reports it.</summary>
    public Task<MeasureSummary> MeasureAsync(long appId, string? country = null, string? device = null,
                                             IProgress<MeasureStep>? progress = null, CancellationToken ct = default) =>
        RunAsync<MeasureSummary>(["measure", Id(appId), .. Option("country", country), .. Option("device", device)], ct,
                                 line => { if (ParseStep(line) is { } step) progress?.Report(step); });

    public Task<IReadOnlyList<SearchResultApp>> SearchAsync(string term, string country, string device = "iphone", int limit = 25,
                                                            CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<SearchResultApp>>(
            ["search", "--country", country, "--device", device, "--limit", limit.ToString(CultureInfo.InvariantCulture), "--", term], ct);

    public Task<IReadOnlyList<string>> HintsAsync(string seed, string country, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<string>>(["hints", "--country", country, "--", seed], ct);

    public Task<DifficultyReport> DifficultyAsync(string term, string country, string device = "iphone", CancellationToken ct = default) =>
        RunAsync<DifficultyReport>(["difficulty", "--country", country, "--device", device, "--", term], ct);

    /// <summary>The issues, also when aso exits with 1 because one of them is an error.</summary>
    public async Task<IReadOnlyList<ValidationIssue>> ValidateAsync(string title, string subtitle, string keywords, CancellationToken ct = default)
    {
        var result = await cli.RunAsync(["--json", "validate", "--title", title, "--subtitle", subtitle, "--keywords", keywords], null, null, ct)
            .ConfigureAwait(false);
        if (result.ExitCode is not (0 or 1) || string.IsNullOrWhiteSpace(result.Output)) throw AsoCliException.From(result);
        return Json.Parse<IReadOnlyList<ValidationIssue>>(result.Output, "validate");
    }

    /// <summary>Every market not measured within the stored staleHours, across all apps (the start-up refresh).</summary>
    public Task<MeasureSummary> MeasureStaleAsync(IProgress<MeasureStep>? progress = null, CancellationToken ct = default) =>
        RunAsync<MeasureSummary>(["measure", "--stale"], ct, line => { if (ParseStep(line) is { } step) progress?.Report(step); });

    // MARK: Ratings, reviews and competitors

    /// <summary>Reads ratings in the app's markets, or in every storefront (one public request each).</summary>
    public Task<RatingsCheck> CheckRatingsAsync(long appId, bool everyStorefront = false, CancellationToken ct = default) =>
        RunAsync<RatingsCheck>(["ratings", "check", Id(appId), .. Flag("all", everyStorefront)], ct);

    public Task<IReadOnlyList<RatingRow>> RatingsAsync(long appId, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<RatingRow>>(["ratings", "list", Id(appId)], ct);

    /// <summary>Reads the newest written reviews in the app's markets, or in every storefront; unseen ones are marked new.</summary>
    public Task<ReviewsCheck> CheckReviewsAsync(long appId, bool everyStorefront = false, CancellationToken ct = default) =>
        RunAsync<ReviewsCheck>(["reviews", "check", Id(appId), .. Flag("all", everyStorefront)], ct);

    /// <summary>Every stored review; the window filters them itself.</summary>
    public Task<ReviewsReport> ReviewsAsync(long appId, CancellationToken ct = default) =>
        RunAsync<ReviewsReport>(["reviews", "list", Id(appId)], ct);

    /// <param name="depth">How deep in each result list to look (1–50).</param>
    public Task<CompetitorsReport> CompetitorsAsync(long appId, string country, string device, int depth, CancellationToken ct = default) =>
        RunAsync<CompetitorsReport>(["competitors", Id(appId), "--country", country, "--device", device, "--depth",
                                     depth.ToString(CultureInfo.InvariantCulture)], ct);

    // MARK: Releases and changes

    /// <summary>App Store releases (recorded when measuring or checking ratings) and notes, newest first.</summary>
    public Task<IReadOnlyList<Marker>> MarkersAsync(long appId, CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<Marker>>(["markers", "list", Id(appId)], ct);

    public Task<Marker> AddNoteAsync(long appId, string title, DateTimeOffset date, CancellationToken ct = default) =>
        RunAsync<Marker>(["markers", "add", Id(appId), "--title", title, "--date", date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)], ct);

    public async Task RemoveMarkerAsync(long appId, long markerId, CancellationToken ct = default) =>
        await RunAsync<JsonElement>(["markers", "remove", Id(appId), Id(markerId)], ct).ConfigureAwait(false);

    public Task<ImpactReport> ImpactAsync(long appId, long markerId, CancellationToken ct = default) =>
        RunAsync<ImpactReport>(["impact", Id(appId), Id(markerId)], ct);
    // MARK: Settings

    public Task<EngineSettings> SettingsAsync(CancellationToken ct = default) => RunAsync<EngineSettings>(["settings"], ct);

    public Task<EngineSettings> SetSettingAsync(string name, string value, CancellationToken ct = default) =>
        RunAsync<EngineSettings>(["settings", "set", name, "--", value], ct);

    public Task<EngineSettings> ResetSettingsAsync(CancellationToken ct = default) => RunAsync<EngineSettings>(["settings", "reset"], ct);

    // MARK: Connections (keys go through stdin or a key file, never arguments)

    public Task<IReadOnlyList<ConnectionStatus>> ConnectionsAsync(CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<ConnectionStatus>>(["connections"], ct);

    /// <param name="key">Either a path to the .pem file or the pasted PEM text.</param>
    public Task<ConnectionStatus> SaveAppleAdsAsync(string clientId, string keyId, string orgId, KeySource key, CancellationToken ct = default) =>
        RunAsync<ConnectionStatus>(["connections", "set", "apple-ads", "--client-id", clientId, "--key-id", keyId, "--org-id", orgId, .. key.Arguments("key")],
                                   ct, standardInput: key.Text);

    /// <param name="keyId">Optional when the key file keeps Apple's name, AuthKey_&lt;KEYID&gt;.p8.</param>
    public Task<ConnectionStatus> SaveAppStoreConnectAsync(string? keyId, string issuerId, KeySource key, CancellationToken ct = default) =>
        RunAsync<ConnectionStatus>(["connections", "set", "asc", "--issuer-id", issuerId, .. Option("key-id", keyId), .. key.Arguments("key")],
                                   ct, standardInput: key.Text);

    public Task<ConnectionStatus> SaveOpenRouterKeyAsync(string apiKey, CancellationToken ct = default) =>
        RunAsync<ConnectionStatus>(["connections", "set", "openrouter", "--key-stdin"], ct, standardInput: apiKey);

    /// <param name="keys">One key per line.</param>
    public Task<ConnectionStatus> SaveRevenueCatKeysAsync(string keys, CancellationToken ct = default) =>
        RunAsync<ConnectionStatus>(["connections", "set", "revenuecat", "--keys-stdin"], ct, standardInput: keys);

    /// <summary>One authenticated call against the service; returns what it answered.</summary>
    public async Task<string> VerifyConnectionAsync(string service, CancellationToken ct = default) =>
        (await RunAsync<VerifyResult>(["connections", "verify", service], ct).ConfigureAwait(false)).Result;

    public async Task RemoveConnectionAsync(string service, CancellationToken ct = default) =>
        await RunAsync<JsonElement>(["connections", "remove", service], ct).ConfigureAwait(false);

    internal static MeasureStep? ParseStep(string line) => Parse<MeasureStep>(line);

    /// <summary>One JSON Lines progress object, or null for any other stderr line.</summary>
    private static T? Parse<T>(string line) where T : class
    {
        if (!line.StartsWith('{')) return null;
        try { return JsonSerializer.Deserialize<T>(line, Json.Options); }
        catch (JsonException) { return null; }
    }

    private async Task<T> RunAsync<T>(IReadOnlyList<string> arguments, CancellationToken ct, Action<string>? onErrorLine = null,
                                      string? standardInput = null)
    {
        // Global options go first: everything after a "--" is a keyword or term.
        var result = await cli.RunAsync(["--json", .. arguments], standardInput, onErrorLine, ct).ConfigureAwait(false);
        if (result.ExitCode != 0) throw AsoCliException.From(result);
        return Json.Parse<T>(result.Output, arguments[0]);
    }

    /// <summary>For commands that print their result and exit with 1 when it is not a success.</summary>
    private async Task<T> RunWithResultAsync<T>(IReadOnlyList<string> arguments, CancellationToken ct)
    {
        var result = await cli.RunAsync(["--json", .. arguments], null, null, ct).ConfigureAwait(false);
        if (result.ExitCode is not (0 or 1) || string.IsNullOrWhiteSpace(result.Output)) throw AsoCliException.From(result);
        return Json.Parse<T>(result.Output, arguments[0]);
    }

    private static string Id(long appId) => appId.ToString(CultureInfo.InvariantCulture);

    private static string[] Option(string name, string? value) => string.IsNullOrWhiteSpace(value) ? [] : [$"--{name}", value];

    private static string[] Flag(string name, bool on) => on ? [$"--{name}"] : [];
}

/// <summary>Where a private key comes from: a file aso reads itself, or pasted text sent through stdin.</summary>
public sealed record KeySource(string? FilePath, string? Text)
{
    public static KeySource File(string path) => new(path, null);
    public static KeySource Pasted(string text) => new(null, text);

    internal string[] Arguments(string option) => FilePath is not null ? [$"--{option}-file", FilePath] : [$"--{option}-stdin"];
}
