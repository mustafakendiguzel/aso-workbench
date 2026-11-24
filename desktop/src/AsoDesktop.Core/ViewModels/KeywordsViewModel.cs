using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>A keyword row as the table shows it; every value comes from the engine's report.</summary>
public sealed record KeywordRow(KeywordReportRow Report)
{
    public string Keyword => Report.Keyword;
    public string Market => $"{Report.Country} {Report.Device}";
    public string Rank => Report.RankLabel;

    /// <summary>For sorting only: "outside the top N" sorts after N, never-measured last.</summary>
    public int RankOrder => Report.Rank ?? (Report.ObservedCount is { } n ? n + 1 : int.MaxValue);

    public string Delta => Report.Delta is { } d ? (d > 0 ? $"+{d}" : d.ToString(CultureInfo.CurrentCulture)) : "";
    public string DeltaAgainst => Report.DeltaAgainst;
    public string Difficulty => Report.Difficulty is { } d ? Math.Round(d).ToString(CultureInfo.CurrentCulture) : "";
    public double DifficultyOrder => Report.Difficulty ?? double.MaxValue;
    public string Brand => Report.BrandLike ? "brand" : "";
    public string Measured => Report.MeasuredAt?.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) ?? "never";
    public string? Failure => Report.Failure;
}

public sealed partial class KeywordsViewModel(AsoClient client, StatusViewModel status) : ObservableObject
{
    public static IReadOnlyList<string> Devices { get; } = ["iphone", "ipad", "mac"];
    public static IReadOnlyList<string> DeltaReferences { get; } = ["lastMarker", "previous", "first", "week"];

    public ObservableCollection<KeywordRow> Rows { get; } = [];

    /// <summary>Called after keywords were added, removed or measured, so market lists can update their counts.</summary>
    public Func<Task>? MarketsChanged { get; set; }

    [ObservableProperty]
    public partial AppRecord? App { get; set; }

    /// <summary>The market whose keywords are shown, added and measured, as in the macOS app.</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddKeywordsCommand), nameof(MeasureCommand), nameof(RefreshCommand))]
    public partial MarketSummary? Market { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddKeywordsCommand))]
    public partial string NewKeywords { get; set; } = "";

    [ObservableProperty]
    public partial string Delta { get; set; } = "lastMarker";

    [ObservableProperty]
    public partial KeywordRow? SelectedRow { get; set; }

    [ObservableProperty]
    public partial double MeasureFraction { get; set; }

    [ObservableProperty]
    public partial string? MeasureStepText { get; set; }

    /// <summary>One keyword per line or comma; blanks and repeats (ignoring case) are dropped.</summary>
    public static IReadOnlyList<string> ParseKeywords(string text) =>
        text.Split(['\n', '\r', ','], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

    private bool HasMarket() => App is not null && Market is not null;

    [RelayCommand(CanExecute = nameof(HasMarket))]
    private Task RefreshAsync() => App is not { } app || Market is not { } market ? Task.CompletedTask : status.RunAsync("Loading keywords…", async () =>
    {
        await ReloadAsync(app, market).ConfigureAwait(true);
        status.Info(Rows.Count == 0 ? $"No keywords in {market.Title} yet." : $"{Rows.Count} keyword(s) in {market.Title}.");
    });

    private bool CanAddKeywords() => HasMarket() && ParseKeywords(NewKeywords).Count > 0;

    [RelayCommand(CanExecute = nameof(CanAddKeywords))]
    private Task AddKeywordsAsync() => App is not { } app || Market is not { } market ? Task.CompletedTask : status.RunAsync("Adding keywords…", async () =>
    {
        var result = await client.AddKeywordsAsync(app.TrackId, ParseKeywords(NewKeywords), market.Country, market.Device).ConfigureAwait(true);
        NewKeywords = "";
        await ReloadAsync(app, market).ConfigureAwait(true);
        await NotifyMarketsAsync().ConfigureAwait(true);
        status.Info($"Added {result.Added.Count} keyword(s) in {result.Market}."
                    + (result.AlreadyTracked.Count > 0 ? $" Already tracked: {string.Join(", ", result.AlreadyTracked)}." : ""));
    });

    [RelayCommand]
    private Task RemoveKeywordAsync(KeywordRow? row) => App is not { } app || Market is not { } market || row is null ? Task.CompletedTask :
        status.RunAsync($"Removing {row.Keyword}…", async () =>
        {
            await client.RemoveKeywordsAsync(app.TrackId, [row.Keyword], row.Report.Country, row.Report.Device).ConfigureAwait(true);
            await ReloadAsync(app, market).ConfigureAwait(true);
            await NotifyMarketsAsync().ConfigureAwait(true);
            status.Info($"Removed {row.Keyword} from {row.Market}.");
        });

    /// <summary>Fresh rank checks for every keyword of the market; cancellable (the Stop button binds to MeasureCancelCommand).</summary>
    [RelayCommand(CanExecute = nameof(HasMarket), IncludeCancelCommand = true)]
    private Task MeasureAsync(CancellationToken cancellationToken) => App is not { } app || Market is not { } market ? Task.CompletedTask :
        status.RunAsync("Measuring ranks, about 3 seconds per keyword…", async () =>
        {
            MeasureFraction = 0;
            var progress = new Progress<MeasureStep>(ShowStep);
            try
            {
                var summary = await client.MeasureMarketAsync(app.TrackId, market.Country, market.Device, progress, cancellationToken)
                    .ConfigureAwait(true);
                await ReloadAsync(app, market).ConfigureAwait(true);
                await NotifyMarketsAsync().ConfigureAwait(true);
                status.Info(summary.Measured == 0
                    ? "Nothing to measure. Add keywords first."
                    : $"Measured {summary.Measured}: {summary.Found} ranked, {summary.Outside} outside the results, {summary.Failed} failed.");
            }
            finally
            {
                MeasureStepText = null;
            }
        });

    internal void ShowStep(MeasureStep step)
    {
        MeasureFraction = step.Total == 0 ? 0 : (double)step.Completed / step.Total;
        MeasureStepText = $"{step.Completed}/{step.Total}  {step.Keyword}  {step.Outcome}";
    }

    partial void OnDeltaChanged(string value)
    {
        if (HasMarket()) RefreshCommand.Execute(null);
    }

    partial void OnAppChanged(AppRecord? oldValue, AppRecord? newValue)
    {
        if (oldValue?.TrackId == newValue?.TrackId) return;   // refreshed details of the same app
        Market = null;
    }

    partial void OnMarketChanged(MarketSummary? oldValue, MarketSummary? newValue)
    {
        if (SameMarket(oldValue, newValue)) return;   // the same market with a refreshed count
        Rows.Clear();
        SelectedRow = null;
    }

    /// <summary>Markets are the same when country and device match; counts and dates may differ between reads.</summary>
    public static bool SameMarket(MarketSummary? a, MarketSummary? b) =>
        a is not null && b is not null && a.Country == b.Country && a.Device == b.Device;

    private Task NotifyMarketsAsync() => MarketsChanged?.Invoke() ?? Task.CompletedTask;

    private async Task ReloadAsync(AppRecord app, MarketSummary market)
    {
        var rows = await client.ListKeywordsAsync(app.TrackId, market.Country, market.Device, Delta).ConfigureAwait(true);
        if (App?.TrackId != app.TrackId || !SameMarket(Market, market)) return;   // the selection moved on while loading
        Rows.Clear();
        foreach (var row in rows) Rows.Add(new KeywordRow(row));
    }
}
