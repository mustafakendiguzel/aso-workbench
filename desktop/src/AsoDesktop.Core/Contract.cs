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
    string? Failure);

public sealed record AddedKeywords(string Market, IReadOnlyList<string> Added, IReadOnlyList<string> AlreadyTracked);

public sealed record MeasureSummary(int Measured, int Found, int Outside, int Failed);

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

public sealed record DifficultyComponent(string Name, string Weight, double Value, string Explanation);

public sealed record DifficultyReport(double Score, string Tier, int SampleSize, IReadOnlyList<DifficultyComponent> Components);

public enum ValidationSeverity
{
    Info = 0,
    Warning = 1,
    Error = 2,
}

public sealed record ValidationIssue(string Field, ValidationSeverity Severity, string Message);

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
