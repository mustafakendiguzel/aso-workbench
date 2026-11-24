using System.Text.Json;
using System.Text.Json.Serialization;

namespace AsoDesktop.Core;

// The JSON that `aso --json` prints (see docs/CLI.md). Absent values are absent in the JSON and null here:
// "not measured" is not rank 0, and no popularity source means no popularity.

/// <summary>A tracked app.</summary>
public sealed record AppRecord(
    [property: JsonPropertyName("trackID")] long TrackId,
    [property: JsonPropertyName("bundleID")] string? BundleId,
    string Name,
    string SellerName,
    [property: JsonPropertyName("iconURL")] string? IconUrl,
    string? PrimaryGenre,
    string? StoreVersion,
    DateTimeOffset CreatedAt,
    string? AdsGenre = null);

/// <summary>A market of an app (<c>aso market list</c>).</summary>
public sealed record MarketSummary(string Country, string CountryName, string Device, int Keywords, DateTimeOffset? LastMeasuredAt)
{
    public string Title => $"{Country} · {Device}";
}

/// <summary>An App Store country (<c>aso storefronts</c>).</summary>
public sealed record StorefrontInfo(string Code, string Name, string Language)
{
    public string Title => $"{Name} ({Code})";
}

/// <summary>An Apple Ads genre (<c>aso genres</c>).</summary>
public sealed record GenreInfo(string Id, string Name);

/// <summary>One tracked keyword as reports show it.</summary>
public sealed record KeywordReportRow(
    string Keyword,
    string Country,
    string Device,
    string Status,
    int? Rank,
    int? ObservedCount,
    string RankLabel,
    int? Delta,
    string DeltaAgainst,
    double? Difficulty,
    int? Popularity,
    double? Opportunity,
    bool BrandLike,
    bool Golden,
    DateTimeOffset? MeasuredAt,
    string? Failure,
    string? DifficultyTier = null,
    double? Fit = null,
    int? MedianRatingsTop10 = null,
    string? RatingMass = null,
    int? TitleMatchesTop10 = null,
    int? DistinctSellersTop10 = null,
    string? Provider = null,
    string Note = "",
    string? PopularitySource = null,
    int? PopularityBelow = null,
    string? PopularityGenre = null,
    DateTimeOffset? PopularityMonth = null,
    AdsTotals? Ads = null)
{
    /// <summary>On Apple's list the score; not on it "&lt; N" (below its lowest score N); empty before the first refresh.</summary>
    public string PopularityLabel => Popularity is { } value ? value.ToString(System.Globalization.CultureInfo.InvariantCulture)
        : PopularitySource == "belowRange" ? (PopularityBelow is { } below ? $"< {below}" : "< list") : "";
}

/// <summary>Everything the inspector shows for one keyword (<c>aso keywords show</c>).</summary>
public sealed record KeywordDetail(
    KeywordReportRow Row,
    KeywordDetailSummary Summary,
    IReadOnlyList<KeywordObservation> Observations,
    IReadOnlyList<TopResult> TopResults,
    DifficultyReport? Difficulty);

/// <summary>Latest successful rank, best rank found, measurements that succeeded, and how many of those were outside.</summary>
public sealed record KeywordDetailSummary(int? Latest, int? Best, int Measurements, int Outside);

/// <summary>One measurement attempt; <c>Rank</c> is set when the app was found.</summary>
public sealed record KeywordObservation(DateTimeOffset FetchedAt, string Status, int? Rank, int ObservedCount, string Label, string Provider, string? Failure);

/// <summary>One of the latest top results; <c>IsOwnApp</c> marks the tracked app or another app from its seller.</summary>
public sealed record TopResult(
    int Position,
    [property: JsonPropertyName("trackID")] long TrackId,
    string Name,
    string SellerName,
    int? RatingCount,
    double? AverageRating,
    bool IsOwnApp);

public sealed record AddedKeywords(string Market, IReadOnlyList<string> Added, IReadOnlyList<string> AlreadyTracked);

/// <summary>A measurement run; with Apple Ads connected, the popularity refresh that followed it, or why it failed.</summary>
public sealed record MeasureSummary(int Measured, int Found, int Outside, int Failed,
    IReadOnlyList<PopularityRefresh>? Popularity = null, string? PopularityError = null);

/// <summary>What <c>aso revenue refresh</c> read; a failure is one key's message.</summary>
public sealed record RevenueRefresh(int Projects, IReadOnlyList<string> Failures);

/// <summary>The app's RevenueCat project (<c>aso revenue show</c>); everything is absent when no project matches.</summary>
public sealed record RevenueReport(string? Match, RevenueSnapshot? Latest, double? MrrChange, IReadOnlyList<RevenueSnapshot> History);

public sealed record RevenueSnapshot(
    [property: JsonPropertyName("projectID")] string ProjectId,
    string ProjectName,
    [property: JsonPropertyName("bundleIDs")] IReadOnlyList<string> BundleIds,
    IReadOnlyList<string> AppNames,
    double Mrr,
    int ActiveSubscriptions,
    double Revenue28d,
    int NewCustomers28d,
    int ActiveTrials,
    int ActiveUsers28d,
    DateTimeOffset FetchedAt);

/// <summary>Your own Apple Ads results for one keyword in one storefront over the synced window.</summary>
public sealed record AdsTotals(int Impressions, int Taps, int Installs, double Spend, string Currency);

/// <summary>What <c>aso ads sync</c> read.</summary>
public sealed record AdsSync(int Campaigns, int Matched, int Rows, DateTimeOffset PeriodStart, DateTimeOffset PeriodEnd);

/// <summary>The app's stored campaign results (<c>aso ads list</c>); the dates are absent before the first sync.</summary>
public sealed record AdsReport(DateTimeOffset? SyncedAt, DateTimeOffset? PeriodStart, DateTimeOffset? PeriodEnd,
                               IReadOnlyList<AdsStorefront> Storefronts, IReadOnlyList<AdsKeywordStat> Keywords);

public sealed record AdsStorefront(string Country, string CountryName, int Impressions, int Taps, int Installs, double Spend, string Currency,
                                   double? CostPerInstall = null, double? TapToInstall = null);

public sealed record AdsKeywordStat(
    [property: JsonPropertyName("campaignID")] long CampaignId,
    string CampaignName,
    string Keyword,
    string MatchType,
    string Country,
    string Currency,
    int Impressions,
    int Taps,
    int Installs,
    double Spend);

/// <summary>Keyword candidates for a market (<c>aso discover</c>); nothing is stored until keywords are added.</summary>
public sealed record DiscoveryReport(
    string Market,
    string? Competitor,
    IReadOnlyList<string> Seeds,
    bool AppleAds,
    bool Jev,
    int WithPopularity,
    int Measured,
    int Golden,
    IReadOnlyList<DiscoveryCandidate> Candidates);

/// <summary>One candidate; absent values were not looked up (no key, or not among the most promising).</summary>
public sealed record DiscoveryCandidate(
    string Keyword,
    IReadOnlyList<string> Sources,
    bool Tracked,
    bool Golden,
    bool GoldenLead,
    int? Popularity = null,
    string? PopularitySource = null,
    string? PopularityGenre = null,
    double? Brand = null,
    double? Natural = null,
    string? Intent = null,
    double? Fit = null,
    double? Difficulty = null,
    string? DifficultyTier = null,
    double? Opportunity = null);

/// <summary>One line of <c>discover --json</c> progress on stderr.</summary>
public sealed record DiscoveryStep(string Step, int Completed, int Total);

/// <summary>What one popularity refresh found in one country (<c>aso popularity</c>).</summary>
public sealed record PopularityRefresh(
    string Country,
    string? Genre,
    DateTimeOffset PeriodStart,
    DateTimeOffset PeriodEnd,
    int Keywords,
    int OnList,
    int BelowRange,
    int? Floor,
    IReadOnlyList<string> GenresFound);

/// <summary>One line of <c>measure --json</c> progress on stderr.</summary>
public sealed record MeasureStep(int Completed, int Total, string Market, string Keyword, string Outcome, string Status);

public sealed record SearchResultApp(
    [property: JsonPropertyName("trackID")] long TrackId,
    string Name,
    string SellerName,
    double? AverageRating,
    int? RatingCount,
    string? PrimaryGenre,
    string? Version,
    [property: JsonPropertyName("iconURL")] string? IconUrl = null);

/// <summary>One part of the difficulty score, as the engine names and weighs it.</summary>
public sealed record DifficultyComponent(string Name, string Weight, double Value, string Explanation);

public sealed record DifficultyReport(double Score, string Tier, int SampleSize, IReadOnlyList<DifficultyComponent> Components);

/// <summary>Ratings in one storefront (<c>aso ratings list</c>): the latest reading, the change since the previous one, and
/// when a new rating was last seen between two readings.</summary>
public sealed record RatingRow(
    string Country,
    string CountryName,
    int Count,
    double? Average,
    int? Delta,
    DateTimeOffset? PreviousAt,
    DateTimeOffset CheckedAt,
    DateTimeOffset? LastNewAt)
{
    public string Title => $"{CountryName} ({Country})";
}

/// <summary><c>aso ratings check</c>: readings stored, ratings that arrived since the previous reading, and the storefronts that
/// failed or have no ratings for the app.</summary>
public sealed record RatingsCheck(int Storefronts, int Recorded, int NewRatings, IReadOnlyList<string> Failed, IReadOnlyList<string> Unavailable,
                                  Marker? NewRelease = null);

/// <summary>A stored written review; <c>IsNew</c> marks one first seen in the most recent check.</summary>
public sealed record StoredReview(
    string Id,
    string Country,
    string Title,
    string Body,
    int Rating,
    string Author,
    string? Version,
    DateTimeOffset? Date,
    DateTimeOffset FetchedAt,
    bool IsNew);

/// <summary><c>aso reviews list</c>: totals over every stored review (stars from one to five), and the reviews newest first.</summary>
public sealed record ReviewsReport(int Stored, int New, double? Average, IReadOnlyList<int> Stars, IReadOnlyList<string> Countries,
                                   IReadOnlyList<StoredReview> Reviews);

public sealed record ReviewsCheck(int Storefronts, int Added, int Stored, IReadOnlyList<string> Failed);

public sealed record CompetitorAppearance(string Keyword, int Position);

/// <summary>An app seen in the latest results of the tracked keywords (<c>aso competitors</c>).</summary>
public sealed record Competitor(
    [property: JsonPropertyName("trackID")] long TrackId,
    string Name,
    string SellerName,
    [property: JsonPropertyName("bundleID")] string? BundleId,
    [property: JsonPropertyName("iconURL")] string? IconUrl,
    string? PrimaryGenre,
    int? RatingCount,
    double? AverageRating,
    DateTimeOffset? CurrentVersionReleaseDate,
    int Keywords,
    int Top10,
    double AveragePosition,
    IReadOnlyList<CompetitorAppearance> Appearances);

public sealed record CompetitorsReport(string Market, int Depth, int KeywordsMeasured, IReadOnlyList<Competitor> Competitors);

/// <summary>A point on the app's timeline: an App Store release (<c>Kind</c> "release"), a note ("note") or a listing applied to App Store Connect ("change").</summary>
public sealed record Marker(long Id, DateTimeOffset Date, string Kind, string Title, string? Version, string? Country)
{
    public bool IsRelease => Kind == "release";
}

/// <summary>One keyword's rank before and after a marker, weighted by what it is worth (<c>aso impact</c>).</summary>
public sealed record ImpactRow(
    string Keyword,
    string Country,
    string Device,
    int? Before,
    DateTimeOffset BeforeAt,
    int? After,
    DateTimeOffset AfterAt,
    int Depth,
    int Delta,
    int? Popularity,
    double? Difficulty,
    double? Fit,
    bool BrandLike,
    double Value,
    double Gain,
    string Tier);

public sealed record ImpactReport(Marker Marker, int Improved, int Worsened, int Same, double Gained, double Lost, double Net,
                                  IReadOnlyList<ImpactRow> Rows);
public enum ValidationSeverity
{
    Info = 0,
    Warning = 1,
    Error = 2,
}

public sealed record ValidationIssue(string Field, ValidationSeverity Severity, string Message);

/// <summary>The six text fields of one locale's listing; also what <c>aso metadata draft --stdin</c> reads.</summary>
public sealed record MetadataFields(string Name, string Subtitle, string Keywords, string PromotionalText, string Description, string WhatsNew)
{
    public static readonly MetadataFields Empty = new("", "", "", "", "", "");
}

/// <summary>What Apple holds for a locale: pulled from App Store Connect ("asc") or typed in ("manual").</summary>
public sealed record MetadataBaseline(string Locale, MetadataFields Fields, string Source, string? AppInfoLocalizationId, string? VersionLocalizationId,
                                     string? VersionString, string? VersionState, DateTimeOffset FetchedAt);

/// <summary>A locale worth writing (<c>aso metadata locales</c>).</summary>
public sealed record MetadataLocale(string Locale, string Name, string? Market, string? Baseline, bool HasDraft, int Changes, int Errors);

/// <summary>A listing language the App Store knows (<c>aso locales</c>).</summary>
public sealed record LocaleInfo(string Id, string Name);

public sealed record RulesFinding(string Kind, string Rule, string Message);

public sealed record RulesSummary(int Score, int CharactersUsed, IReadOnlyList<string> IndexedWords, IReadOnlyList<RulesFinding> Findings);

public sealed record FieldChange(string Field, string Before, string After);

public sealed record KeywordChange(IReadOnlyList<string> Kept, IReadOnlyList<string> Added, IReadOnlyList<string> Removed);

public sealed record LegalFooterSettings(bool Enabled, string EulaUrl, string PrivacyUrl, string Note);

public sealed record LegalState(LegalFooterSettings Settings, string EffectiveEula, bool InDescription);

/// <summary>One locale's draft with its checks and its difference from the baseline (<c>aso metadata show</c>).</summary>
public sealed record MetadataReport(
    string Locale,
    string Name,
    string? Market,
    MetadataBaseline? Baseline,
    MetadataFields Draft,
    DateTimeOffset? DraftUpdatedAt,
    IReadOnlyList<ValidationIssue> Issues,
    RulesSummary Rules,
    IReadOnlyList<FieldChange> Changes,
    KeywordChange? KeywordChange,
    LegalState Legal);

/// <summary>Drafts changed by a footer insert or a What's New fill.</summary>
public sealed record MetadataBatch(IReadOnlyList<string> Changed, int Locales);

/// <summary>Every locale read from App Store Connect as the baseline (<c>aso metadata pull</c>).</summary>
public sealed record MetadataPull(IReadOnlyList<string> Locales, string? Version, string? VersionState, bool Editable, string? PrivacyUrl);

/// <summary>An iOS version on App Store Connect; only an editable one takes a new listing.</summary>
public sealed record AscVersion(string Id, string Version, string State, bool Editable);

public sealed record ScreenshotCopy(int Sets, int Copied, int Skipped, IReadOnlyList<string> Errors);

/// <summary>What applying a locale would send, read from App Store Connect without writing (<c>aso metadata plan</c>).</summary>
public sealed record PublishPlan(
    string Locale,
    string Name,
    bool Exists,
    string? Version,
    string? VersionState,
    bool Editable,
    MetadataFields Draft,
    IReadOnlyList<FieldChange> Changes,
    IReadOnlyList<string> Automatic,
    IReadOnlyList<ValidationIssue> Errors,
    string? Blocked)
{
    public bool IsReady => Blocked is null;
}

/// <summary>One locale written (or not) to App Store Connect: applied, partial, refused or failed.</summary>
public sealed record PublishResult(string Locale, string Status, string Message, IReadOnlyList<FieldChange> Changes, ScreenshotCopy? Screenshots)
{
    public bool Succeeded => Status is "applied" or "partial";
}

/// <summary>One attempt to write a locale's listing (<c>aso metadata log</c>).</summary>
public sealed record ChangeLogEntry(long Id, DateTimeOffset CreatedAt, string Locale, string Status, IReadOnlyList<FieldChange> Changes, string Note,
                                    string BaselineHash, string? ResultHash);

/// <summary>The engine's preferences (<c>aso settings --json</c>).</summary>
public sealed record EngineSettings(
    int ResultDepth,
    double PacingSeconds,
    int GoldenMinPopularity,
    int GoldenMaxDifficulty,
    int WriterEasyDifficulty,
    int WriterMaxDifficulty,
    string DeltaReference,
    bool AutoMeasureOnLaunch,
    int StaleHours,
    string WriterModel,
    [property: JsonPropertyName("adsReferenceAppID")] string AdsReferenceAppId);

/// <summary>A service's stored keys without the secrets (<c>aso connections --json</c>).</summary>
public sealed record ConnectionStatus(string Service, string Title, bool Configured, IReadOnlyDictionary<string, string> Details);

internal sealed record VerifyResult(string Service, string Result);

/// <summary><c>aso --version --json</c>: the engine's version and the data folder it uses.</summary>
public sealed record EngineInfo(string Version, string? DataDirectory);

internal static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public static T Parse<T>(string json, string command)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(json, Options)
                ?? throw new AsoCliException($"aso {command} printed no result.", exitCode: 0);
        }
        catch (JsonException error)
        {
            throw new AsoCliException($"aso {command} printed output this version cannot read: {error.Message}", exitCode: 0);
        }
    }
}
