using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>A candidate as the discovery table shows it.</summary>
public sealed record DiscoveryLine(DiscoveryCandidate Candidate)
{
    public string Keyword => Candidate.Keyword;
    public string Mark => Candidate.Golden ? "golden" : Candidate.GoldenLead ? "lead" : "";
    public string Popularity => Candidate.Popularity is { } p ? p.ToString(CultureInfo.CurrentCulture)
        : Candidate.PopularitySource == "belowRange" ? "< list" : "";
    public int PopularityOrder => Candidate.Popularity ?? (Candidate.PopularitySource == "belowRange" ? 0 : -1);
    public string Difficulty => Candidate.Difficulty is { } d ? Math.Round(d).ToString(CultureInfo.CurrentCulture) : "";
    public double DifficultyOrder => Candidate.Difficulty ?? double.MaxValue;
    public string Opportunity => Candidate.Opportunity is { } o ? Math.Round(o).ToString(CultureInfo.CurrentCulture) : "";
    public double OpportunityOrder => Candidate.Opportunity ?? -1;
    public string Fit => Candidate.Fit is { } f ? f.ToString("P0", CultureInfo.CurrentCulture) : "";
    public string Brand => Candidate.Brand is >= 0.5 ? "brand" : "";
    public string Sources => string.Join(", ", Candidate.Sources);
    public string Tracked => Candidate.Tracked ? "tracked" : "";
}

/// <summary>
/// The macOS app's "Find golden keywords" and "Import keywords from a competitor": candidates from autocomplete, Apple Ads
/// and the competitor's listing, scored by the engine; the chosen ones are added to the market. Nothing is stored before.
/// </summary>
public sealed partial class DiscoveryViewModel(AsoClient client, StatusViewModel status, AppRecord app, MarketSummary market,
                                               Competitor? competitor = null) : ObservableObject
{
    public AppRecord App { get; } = app;
    public MarketSummary Market { get; } = market;
    /// <summary>The app whose listing is mined (from the Competitors tab), or null to expand the seeds only.</summary>
    public Competitor? Competitor { get; } = competitor;

    public string Title => Competitor is { } c ? $"Import keywords from {c.Name}" : "Find golden keywords";

    public string Explanation => Competitor is null
        ? "Your best keywords and title words are expanded with App Store autocomplete and Apple Ads suggestions. Candidates get Apple popularity, Jev filters out other brands and unnatural phrases, and the most promising are measured for difficulty."
        : "Words and two-word phrases from the competitor's title and description, plus autocomplete and Apple Ads suggestions around its title words; then popularity, Jev and difficulty.";

    public ObservableCollection<DiscoveryLine> Rows { get; } = [];

    /// <summary>The table's selection (the view keeps it in step).</summary>
    public IReadOnlyList<DiscoveryLine> SelectedRows
    {
        get => selectedRows;
        set
        {
            selectedRows = value;
            OnPropertyChanged();
            AddSelectedCommand.NotifyCanExecuteChanged();
        }
    }
    private IReadOnlyList<DiscoveryLine> selectedRows = [];

    /// <summary>One per line or comma; empty uses the engine's seeds.</summary>
    [ObservableProperty] public partial string Seeds { get; set; } = "";
    [ObservableProperty] public partial int DifficultyLimit { get; set; } = 25;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Summary), nameof(Missing))]
    public partial DiscoveryReport? Report { get; set; }

    [ObservableProperty] public partial string? StepText { get; set; }

    /// <summary>How many keywords were added; the dialog closes when it is set.</summary>
    [ObservableProperty] public partial int? Added { get; set; }

    public string Summary => Report is not { } r ? "" :
        $"{r.Candidates.Count} candidate(s) · {r.WithPopularity} with an Apple popularity value · {r.Measured} measured for difficulty · {r.Golden} golden · seeds: {string.Join(", ", r.Seeds)}";

    /// <summary>What a missing key leaves out, in the engine's words.</summary>
    public string Missing => Report is not { } r ? "" : string.Join(" ", new[]
    {
        r.AppleAds ? null : "Apple Ads is not connected: no popularity, so no candidate can be golden or is measured for difficulty.",
        r.Jev ? null : "OpenRouter is not connected: other brands and unrelated terms are not filtered out.",
    }.Where(s => s is not null));

    [RelayCommand(IncludeCancelCommand = true)]
    private Task FindAsync(CancellationToken cancellationToken) => status.RunAsync("Finding keyword candidates…", async () =>
    {
        try
        {
            var seeds = KeywordsViewModel.ParseKeywords(Seeds);
            var report = await client.DiscoverAsync(App.TrackId, Market.Country, Market.Device, Competitor?.TrackId, seeds,
                                                    Math.Clamp(DifficultyLimit, 0, 60), new Progress<DiscoveryStep>(ShowStep), cancellationToken)
                .ConfigureAwait(true);
            Report = report;
            Rows.Clear();
            foreach (var candidate in report.Candidates) Rows.Add(new DiscoveryLine(candidate));
            status.Info(Summary);
        }
        finally
        {
            StepText = null;
        }
    });

    internal void ShowStep(DiscoveryStep step) =>
        StepText = step.Total > 0 ? $"{step.Completed + 1}/{step.Total}  {step.Step}" : step.Step;

    /// <summary>The untracked golden candidates, for the view to select.</summary>
    public IReadOnlyList<DiscoveryLine> GoldenRows => Rows.Where(r => r.Candidate.Golden && !r.Candidate.Tracked).ToList();

    private bool CanAdd() => SelectedRows.Any(r => !r.Candidate.Tracked);

    [RelayCommand(CanExecute = nameof(CanAdd))]
    private Task AddSelectedAsync() => status.RunAsync("Adding keywords…", async () =>
    {
        var keywords = SelectedRows.Where(r => !r.Candidate.Tracked).Select(r => r.Keyword).ToList();
        var result = await client.AddKeywordsAsync(App.TrackId, keywords, Market.Country, Market.Device).ConfigureAwait(true);
        status.Info($"Added {result.Added.Count} keyword(s) in {result.Market}. Measure them to see their ranks.");
        Added = result.Added.Count;
    });
}
