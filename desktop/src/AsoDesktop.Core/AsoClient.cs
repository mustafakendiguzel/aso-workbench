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

    internal static MeasureStep? ParseStep(string line)
    {
        if (!line.StartsWith('{')) return null;
        try { return JsonSerializer.Deserialize<MeasureStep>(line, Json.Options); }
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
