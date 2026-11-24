using System.Globalization;
using System.Text.Json;

namespace AsoDesktop.Core;

/// <summary>
/// The aso command as typed calls. Every call runs one <c>aso … --json</c> and parses its stdout; all numbers and
/// verdicts come from the engine, none are computed here.
/// </summary>
public sealed class AsoClient(IAsoCli cli)
{
    public async Task<string> VersionAsync(CancellationToken ct = default) =>
        (await RunAsync<VersionInfo>(["--version"], ct).ConfigureAwait(false)).Version;

    public Task<IReadOnlyList<AppRecord>> ListAppsAsync(CancellationToken ct = default) =>
        RunAsync<IReadOnlyList<AppRecord>>(["app", "list"], ct);

    public Task<AppRecord> AddAppAsync(string reference, string? country, CancellationToken ct = default) =>
        RunAsync<AppRecord>(["app", "add", reference, .. Option("country", country)], ct);

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
        var result = await cli.RunAsync(["--json", "validate", "--title", title, "--subtitle", subtitle, "--keywords", keywords], null, ct)
            .ConfigureAwait(false);
        if (result.ExitCode is not (0 or 1) || string.IsNullOrWhiteSpace(result.Output)) throw AsoCliException.From(result);
        return Json.Parse<IReadOnlyList<ValidationIssue>>(result.Output, "validate");
    }

    internal static MeasureStep? ParseStep(string line)
    {
        if (!line.StartsWith('{')) return null;
        try { return JsonSerializer.Deserialize<MeasureStep>(line, Json.Options); }
        catch (JsonException) { return null; }
    }

    private async Task<T> RunAsync<T>(IReadOnlyList<string> arguments, CancellationToken ct, Action<string>? onErrorLine = null)
    {
        // Global options go first: everything after a "--" is a keyword or term.
        var result = await cli.RunAsync(["--json", .. arguments], onErrorLine, ct).ConfigureAwait(false);
        if (result.ExitCode != 0) throw AsoCliException.From(result);
        return Json.Parse<T>(result.Output, arguments[0]);
    }

    private static string Id(long appId) => appId.ToString(CultureInfo.InvariantCulture);

    private static string[] Option(string name, string? value) => string.IsNullOrWhiteSpace(value) ? [] : [$"--{name}", value];
}
