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
    public static IReadOnlyList<string> DeltaReferences { get; } = ["previous", "first", "week"];

    public ObservableCollection<KeywordRow> Rows { get; } = [];

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddKeywordsCommand), nameof(MeasureCommand), nameof(RefreshCommand))]
    public partial AppRecord? App { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddKeywordsCommand))]
    public partial string NewKeywords { get; set; } = "";

    [ObservableProperty]
    public partial string NewCountry { get; set; } = "US";

    [ObservableProperty]
    public partial string NewDevice { get; set; } = "iphone";

    [ObservableProperty]
    public partial string Delta { get; set; } = "previous";

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

    private bool HasApp() => App is not null;

    [RelayCommand(CanExecute = nameof(HasApp))]
    private Task RefreshAsync() => App is not { } app ? Task.CompletedTask : status.RunAsync("Loading keywords…", async () =>
    {
        await ReloadAsync(app).ConfigureAwait(true);
        status.Info(Rows.Count == 0 ? $"No keywords for {app.Name} yet." : $"{Rows.Count} keyword(s) for {app.Name}.");
    });

    private bool CanAddKeywords() => App is not null && ParseKeywords(NewKeywords).Count > 0;

    [RelayCommand(CanExecute = nameof(CanAddKeywords))]
    private Task AddKeywordsAsync() => App is not { } app ? Task.CompletedTask : status.RunAsync("Adding keywords…", async () =>
    {
        var result = await client.AddKeywordsAsync(app.TrackId, ParseKeywords(NewKeywords), NewCountry.Trim(), NewDevice).ConfigureAwait(true);
        NewKeywords = "";
        await ReloadAsync(app).ConfigureAwait(true);
        status.Info($"Added {result.Added.Count} keyword(s) in {result.Market}."
                    + (result.AlreadyTracked.Count > 0 ? $" Already tracked: {string.Join(", ", result.AlreadyTracked)}." : ""));
    });

    [RelayCommand]
    private Task RemoveKeywordAsync(KeywordRow? row) => App is not { } app || row is null ? Task.CompletedTask :
        status.RunAsync($"Removing {row.Keyword}…", async () =>
        {
            await client.RemoveKeywordsAsync(app.TrackId, [row.Keyword], row.Report.Country, row.Report.Device).ConfigureAwait(true);
            await ReloadAsync(app).ConfigureAwait(true);
            status.Info($"Removed {row.Keyword} from {row.Market}.");
        });

    /// <summary>Fresh rank checks for every keyword of the app; cancellable (the Stop button binds to MeasureCancelCommand).</summary>
    [RelayCommand(CanExecute = nameof(HasApp), IncludeCancelCommand = true)]
    private Task MeasureAsync(CancellationToken cancellationToken) => App is not { } app ? Task.CompletedTask :
        status.RunAsync("Measuring ranks, about 3 seconds per keyword…", async () =>
        {
            MeasureFraction = 0;
            var progress = new Progress<MeasureStep>(ShowStep);
            try
            {
                var summary = await client.MeasureAsync(app.TrackId, progress: progress, ct: cancellationToken).ConfigureAwait(true);
                await ReloadAsync(app).ConfigureAwait(true);
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
        if (App is not null) RefreshCommand.Execute(null);
    }

    partial void OnAppChanged(AppRecord? value)
    {
        Rows.Clear();
        SelectedRow = null;
    }

    private async Task ReloadAsync(AppRecord app)
    {
        var rows = await client.ListKeywordsAsync(app.TrackId, delta: Delta).ConfigureAwait(true);
        if (App?.TrackId != app.TrackId) return;   // the selection moved on while loading
        Rows.Clear();
        foreach (var row in rows) Rows.Add(new KeywordRow(row));
    }
}
