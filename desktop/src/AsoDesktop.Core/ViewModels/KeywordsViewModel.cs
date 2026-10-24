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
    public string Popularity => Report.PopularityLabel;

    /// <summary>For sorting only: every score, then "below N" (a higher N first; it may be under any score), then never read.</summary>
    public double PopularityOrder => Report.Popularity
        ?? (Report.PopularitySource == "belowRange" ? -1 + (Report.PopularityBelow ?? 0) / 1000.0 : -2);

    public string Golden => Report.Golden ? "golden" : "";

    /// <summary>Your own Apple Ads impressions, taps and installs for this keyword in this storefront (synced on Overview).</summary>
    public string Ads => Report.Ads is { } a
        ? $"{a.Impressions.ToString("N0", CultureInfo.CurrentCulture)} · {a.Taps} taps · {a.Installs} inst."
        : "";
    public int AdsOrder => Report.Ads?.Impressions ?? -1;
    public string Difficulty => Report.Difficulty is { } d ? Math.Round(d).ToString(CultureInfo.CurrentCulture) : "";
    public double DifficultyOrder => Report.Difficulty ?? double.MaxValue;
    public string DifficultyTier => Report.DifficultyTier ?? "";
    public string Brand => Report.BrandLike ? "brand" : "";
    public string Fit => Report.Fit is { } f ? f.ToString("P0", CultureInfo.CurrentCulture) : "";
    public string RatingMass => Report.RatingMass ?? "";
    public int RatingMassOrder => Report.MedianRatingsTop10 ?? -1;
    public string TitleMatches => Report.TitleMatchesTop10 is { } t ? $"{t}/10" : "";
    public int TitleMatchesOrder => Report.TitleMatchesTop10 ?? -1;
    public string Measured => Report.MeasuredAt?.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) ?? "never";
    public string? Failure => Report.Failure;
    /// <summary>A marker for rows with a note; the note itself is in the inspector.</summary>
    public string HasNote => Report.Note.Length > 0 ? "✎" : "";
}

public sealed partial class KeywordsViewModel(AsoClient client, StatusViewModel status) : ObservableObject
{
    public static IReadOnlyList<string> Devices { get; } = ["iphone", "ipad", "mac"];
    public static IReadOnlyList<string> DeltaReferences { get; } = ["lastMarker", "previous", "first", "week"];

    /// <summary>Every keyword of the market, as the engine reported it.</summary>
    public ObservableCollection<KeywordRow> Rows { get; } = [];

    /// <summary>The rows that pass the filters; the table shows these.</summary>
    public ObservableCollection<KeywordRow> VisibleRows { get; } = [];

    public InspectorViewModel Inspector { get; } = new(client, status);

    /// <summary>The table's selection (the view keeps it in step); commands on "selected" use it.</summary>
    public IReadOnlyList<KeywordRow> SelectedRows
    {
        get => selectedRows;
        set
        {
            selectedRows = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(SelectionText));
            MeasureSelectedCommand.NotifyCanExecuteChanged();
            RemoveSelectedCommand.NotifyCanExecuteChanged();
            RefreshPopularitySelectedCommand.NotifyCanExecuteChanged();
        }
    }
    private IReadOnlyList<KeywordRow> selectedRows = [];

    public string SelectionText => SelectedRows.Count switch { 0 => "", 1 => "1 selected", var n => $"{n} selected" };

    /// <summary>The selected keywords, one per line, for the clipboard.</summary>
    public string SelectedKeywordsText => string.Join(Environment.NewLine, SelectedRows.Select(r => r.Keyword));

    [ObservableProperty] public partial string FilterText { get; set; } = "";
    [ObservableProperty] public partial bool FoundOnly { get; set; }
    [ObservableProperty] public partial bool HideBrands { get; set; }
    /// <summary>100 means no difficulty filter.</summary>
    [ObservableProperty] public partial double MaxDifficulty { get; set; } = 100;

    public string FilterSummary => VisibleRows.Count == Rows.Count ? $"{Rows.Count} keyword(s)" : $"{VisibleRows.Count} of {Rows.Count} keyword(s)";

    /// <summary>The macOS app's keyword filters: text, found in the results, no brands, difficulty at most.</summary>
    public bool Allows(KeywordRow row) =>
        // Ordinal: a culture-aware comparison breaks under Turkish casing ("SLIDES" would not match "slides").
        (FilterText.Length == 0 || row.Keyword.Contains(FilterText.Trim(), StringComparison.OrdinalIgnoreCase))
        && (!FoundOnly || row.Report.Rank is not null)
        && (!HideBrands || !row.Report.BrandLike)
        && (MaxDifficulty >= 100 || row.Report.Difficulty is { } d && d <= MaxDifficulty);

    partial void OnFilterTextChanged(string value) => ApplyFilters();
    partial void OnFoundOnlyChanged(bool value) => ApplyFilters();
    partial void OnHideBrandsChanged(bool value) => ApplyFilters();
    partial void OnMaxDifficultyChanged(double value) => ApplyFilters();

    [RelayCommand]
    private void ClearFilters()
    {
        FilterText = "";
        FoundOnly = false;
        HideBrands = false;
        MaxDifficulty = 100;
    }

    private void ApplyFilters()
    {
        VisibleRows.Clear();
        foreach (var row in Rows.Where(Allows)) VisibleRows.Add(row);
        OnPropertyChanged(nameof(FilterSummary));
    }

    /// <summary>Called after keywords were added, removed or measured, so market lists can update their counts.</summary>
    public Func<Task>? MarketsChanged { get; set; }

    [ObservableProperty]
    public partial AppRecord? App { get; set; }

    /// <summary>The market whose keywords are shown, added and measured, as in the macOS app.</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddKeywordsCommand), nameof(MeasureCommand), nameof(RefreshCommand), nameof(RefreshPopularityCommand))]
    public partial MarketSummary? Market { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddKeywordsCommand))]
    public partial string NewKeywords { get; set; } = "";

    [ObservableProperty]
    public partial string Delta { get; set; } = "lastMarker";

    [ObservableProperty]
    public partial KeywordRow? SelectedRow { get; set; }

    /// <summary>Apple Ads keys are stored, so popularity can be read (and a measurement reads it too).</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(RefreshPopularityCommand), nameof(RefreshPopularitySelectedCommand))]
    public partial bool AdsConnected { get; set; }

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
                status.Info(summary.Measured == 0 ? "Nothing to measure. Add keywords first." : Describe(summary));
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
        ApplyFilters();
        SelectedRow = null;
        SelectedRows = [];
        MeasureSelectedCommand.NotifyCanExecuteChanged();
    }

    partial void OnSelectedRowChanged(KeywordRow? value) => _ = Inspector.ShowAsync(App, Market, value, Delta);

    private bool HasSelection() => HasMarket() && SelectedRows.Count > 0;

    /// <summary>Fresh rank checks for the selected keywords only (the macOS app's Measure Selected).</summary>
    [RelayCommand(CanExecute = nameof(HasSelection), IncludeCancelCommand = true)]
    private Task MeasureSelectedAsync(CancellationToken cancellationToken) =>
        App is not { } app || Market is not { } market || SelectedRows.Count == 0 ? Task.CompletedTask :
        status.RunAsync($"Measuring {SelectedRows.Count} keyword(s)…", async () =>
        {
            MeasureFraction = 0;
            try
            {
                var summary = await client.MeasureKeywordsAsync(app.TrackId, market.Country, market.Device, SelectedRows.Select(r => r.Keyword).ToList(),
                                                                new Progress<MeasureStep>(ShowStep), cancellationToken).ConfigureAwait(true);
                await ReloadAsync(app, market).ConfigureAwait(true);
                await NotifyMarketsAsync().ConfigureAwait(true);
                status.Info(Describe(summary));
            }
            finally
            {
                MeasureStepText = null;
            }
        });

    private bool CanRefreshPopularity() => HasMarket() && AdsConnected;

    /// <summary>Apple Ads popularity for every keyword of the market (the macOS app's Refresh popularity).</summary>
    [RelayCommand(CanExecute = nameof(CanRefreshPopularity))]
    private Task RefreshPopularityAsync() => RefreshPopularity(null);

    private bool CanRefreshPopularitySelected() => CanRefreshPopularity() && SelectedRows.Count > 0;

    [RelayCommand(CanExecute = nameof(CanRefreshPopularitySelected))]
    private Task RefreshPopularitySelectedAsync() => RefreshPopularity(SelectedRows.Select(r => r.Keyword).ToList());

    private Task RefreshPopularity(IReadOnlyList<string>? keywords) => App is not { } app || Market is not { } market ? Task.CompletedTask :
        status.RunAsync("Reading popularity from Apple Ads…", async () =>
        {
            var refreshes = await client.PopularityAsync(app.TrackId, market.Country, market.Device, keywords).ConfigureAwait(true);
            await ReloadAsync(app, market).ConfigureAwait(true);
            // Popularity changes what each keyword is worth in the Changes report.
            await NotifyMarketsAsync().ConfigureAwait(true);
            status.Info(refreshes.Count == 0 ? "No keywords to read." : Describe(refreshes));
        });

    /// <summary>The measurement as aso words it, with the popularity refresh that followed it.</summary>
    public static string Describe(MeasureSummary summary)
    {
        var text = $"Measured {summary.Measured}: {summary.Found} ranked, {summary.Outside} outside the results, {summary.Failed} failed.";
        if (summary.Popularity is { Count: > 0 } refreshes) text += " " + Describe(refreshes);
        if (summary.PopularityError is { } error) text += $" Popularity was not refreshed: {error}";
        return text;
    }

    /// <summary>"US: 12 of 20 keyword(s) on Apple's list (September 2026); 8 below the published range (under 31)."</summary>
    public static string Describe(IReadOnlyList<PopularityRefresh> refreshes) => string.Join(" ", refreshes.Select(r =>
        $"{r.Country}: {r.OnList} of {r.Keywords} keyword(s) on Apple's list ({Month(r.PeriodStart)})"
        + (r.BelowRange > 0 ? $"; {r.BelowRange} below the published range" + (r.Floor is { } f ? $" (under {f})" : "") : "")
        + "."));

    /// <summary>"September 2026", in UTC, where the month starts.</summary>
    public static string Month(DateTimeOffset date) => date.UtcDateTime.ToString("MMMM yyyy", CultureInfo.InvariantCulture);

    /// <summary>Removes the selected keywords with their measurements (the view asks first).</summary>
    [RelayCommand(CanExecute = nameof(HasSelection))]
    private Task RemoveSelectedAsync() => App is not { } app || Market is not { } market || SelectedRows.Count == 0 ? Task.CompletedTask :
        status.RunAsync($"Removing {SelectedRows.Count} keyword(s)…", async () =>
        {
            var keywords = SelectedRows.Select(r => r.Keyword).ToList();
            var removed = await client.RemoveKeywordsAsync(app.TrackId, keywords, market.Country, market.Device).ConfigureAwait(true);
            SelectedRows = [];
            await ReloadAsync(app, market).ConfigureAwait(true);
            await NotifyMarketsAsync().ConfigureAwait(true);
            status.Info($"Removed {removed} keyword(s) from {market.Title}.");
        });

    /// <summary>The market's keywords as the macOS app exports them; the view saves the text.</summary>
    public async Task<string?> ExportCsvAsync()
    {
        if (App is not { } app || Market is not { } market) return null;
        string? csv = null;
        await status.RunAsync("Exporting keywords…", async () =>
        {
            csv = await client.KeywordsCsvAsync(app.TrackId, market.Country, market.Device, Delta).ConfigureAwait(true);
            status.Info($"Exported {Rows.Count} keyword(s) from {market.Title}.");
        }).ConfigureAwait(true);
        return csv;
    }

    /// <summary>A file name like "keynote-US-iphone-keywords.csv".</summary>
    public string ExportFileName =>
        $"{new string((App?.Name ?? "keywords").Split(':')[0].Where(c => char.IsLetterOrDigit(c) || c == ' ').ToArray()).Trim().Replace(' ', '-').ToLowerInvariant()}" +
        $"-{Market?.Country}-{Market?.Device}-keywords.csv";

    /// <summary>Markets are the same when country and device match; counts and dates may differ between reads.</summary>
    public static bool SameMarket(MarketSummary? a, MarketSummary? b) =>
        a is not null && b is not null && a.Country == b.Country && a.Device == b.Device;

    private Task NotifyMarketsAsync() => MarketsChanged?.Invoke() ?? Task.CompletedTask;

    private async Task ReloadAsync(AppRecord app, MarketSummary market)
    {
        var rows = await client.ListKeywordsAsync(app.TrackId, market.Country, market.Device, Delta).ConfigureAwait(true);
        if (App?.TrackId != app.TrackId || !SameMarket(Market, market)) return;   // the selection moved on while loading
        var selected = SelectedRow?.Keyword;
        Rows.Clear();
        foreach (var row in rows) Rows.Add(new KeywordRow(row));
        ApplyFilters();
        // Keep the inspected keyword selected (and its inspector fresh) across reloads.
        SelectedRow = selected is null ? null : VisibleRows.FirstOrDefault(r => r.Keyword == selected);
    }
}
