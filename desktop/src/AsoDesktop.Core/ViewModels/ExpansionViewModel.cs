using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>A storefront offered to try the keywords in.</summary>
public sealed partial class ExpansionCountry(StorefrontInfo storefront, bool selected) : ObservableObject
{
    public StorefrontInfo Storefront { get; } = storefront;
    public string Label => $"{Storefront.Name} ({Storefront.Code})";

    [ObservableProperty] public partial bool IsSelected { get; set; } = selected;
}

/// <summary>One cell as the results table shows it.</summary>
public sealed record ExpansionLine(ExpansionRow Row)
{
    public string Mark => Row.Candidate ? "★" : "";
    public string Country => Row.Country;
    public string Keyword => Row.Term;
    public string From => Row.Source is { } s ? $"for “{s}”" + (string.IsNullOrEmpty(Row.Meaning) ? "" : $" · {Row.Meaning}") : "";
    public string Rank => Row.Failed ? "Error" : Row.Rank is { } r ? $"#{r}" : $"> {Row.Observed}";
    public int RankOrder => Row.Rank ?? int.MaxValue;
    public string Popularity => Row.Popularity is { } p ? p.ToString(CultureInfo.CurrentCulture)
        : Row.PopularitySource == "belowRange" ? (Row.PopularityBelow is { } b ? $"< {b}" : "< list") : "";
    public int PopularityOrder => Row.Popularity ?? (Row.PopularitySource == "belowRange" ? 0 : -1);
    public string Difficulty => Row.Difficulty is { } d ? Math.Round(d).ToString(CultureInfo.CurrentCulture) : "";
    public double DifficultyOrder => Row.Difficulty ?? double.MaxValue;
    public string Opportunity => Row.Opportunity is { } o ? Math.Round(o).ToString(CultureInfo.CurrentCulture) : "";
    public double OpportunityOrder => Row.Opportunity ?? -1;
    public string Language => Row.LanguageFit is { } f ? f.ToString("P0", CultureInfo.CurrentCulture) : "";
    public string Leader => Row.Leader ?? "";
    public string Tracked => Row.Tracked ? "tracked" : "";
}

/// <summary>
/// The macOS app's "Try keywords in other countries": the market's keywords, and how locals search for the same need (AI local forms),
/// measured in other storefronts in one pass, with rank, Apple popularity, difficulty and language fit; with Track, every cell becomes a tracked
/// keyword with its measurement so nothing is measured twice.
/// </summary>
public sealed partial class ExpansionViewModel : ObservableObject
{
    private readonly AsoClient client;
    private readonly Func<Task> tracked;

    public ExpansionViewModel(AsoClient client, AppRecord app, MarketSummary market, IEnumerable<StorefrontInfo> storefronts, Func<Task> tracked)
    {
        this.client = client;
        this.tracked = tracked;
        App = app;
        Market = market;
        string[] defaults = ["GB", "DE", "FR", "ES", "IT", "BR", "JP", "KR"];
        foreach (var s in storefronts.Where(s => s.Code != market.Country))
        {
            var country = new ExpansionCountry(s, defaults.Contains(s.Code));
            country.PropertyChanged += (_, _) => OnPropertyChanged(nameof(Estimate));
            Countries.Add(country);
        }
    }

    public AppRecord App { get; }
    public MarketSummary Market { get; }
    public string Title => $"Try {App.Name.Split(':')[0].Trim()}'s keywords in other countries";

    public ObservableCollection<ExpansionCountry> Countries { get; } = [];
    public ObservableCollection<ExpansionLine> Rows { get; } = [];

    /// <summary>Comma separated; empty tries the market's first 20 keywords.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Estimate))]
    public partial string Keywords { get; set; } = "";

    /// <summary>Ask the model how locals search for each keyword where the store speaks another language (OpenRouter).</summary>
    [ObservableProperty] public partial bool LocalForms { get; set; } = true;

    /// <summary>Keep every measured cell as a tracked keyword, creating the market when missing.</summary>
    [ObservableProperty] public partial bool Track { get; set; } = true;

    [ObservableProperty] public partial bool CandidatesOnly { get; set; }

    [ObservableProperty] public partial ExpansionReport? Report { get; set; }
    [ObservableProperty] public partial string? StepText { get; set; }
    [ObservableProperty] public partial string? Error { get; set; }

    public IReadOnlyList<string> KeywordList =>
        Keywords.Split([',', '\n'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);

    public IReadOnlyList<string> ChosenCountries => Countries.Where(c => c.IsSelected).Select(c => c.Storefront.Code).ToList();

    /// <summary>About three seconds per search, as the engine paces public search.</summary>
    public string Estimate
    {
        get
        {
            var words = KeywordList.Count > 0 ? KeywordList.Count : Math.Min(20, Market.Keywords);
            var minutes = Math.Max(1, (int)Math.Round(words * ChosenCountries.Count * 3.7 / 60));
            return $"{words} keyword(s) × {ChosenCountries.Count} storefront(s), about {minutes} min (local forms add a few searches per storefront).";
        }
    }

    public string Summary => Report is not { } r ? ""
        : $"{r.Keywords} keyword(s) × {r.Countries.Count} storefront(s): {r.Candidates} candidate(s) (★: popularity 30 or more, a top-30 rank or difficulty 45 or less, in a language people search there)."
          + (r.Tracked > 0 ? $" {r.Tracked} cell(s) tracked with their measurement." : "")
          + (r.LocalizationCost.Count > 0 ? $" Local forms cost: {string.Join(", ", r.LocalizationCost)}." : "");

    public string Missing => Report is not { } r ? "" : string.Join(" ", new[]
    {
        r.AppleAds ? null : "Apple Ads is not connected: no popularity, so no cell can be a candidate.",
        r.LanguageChecked ? null : "OpenRouter is not connected: no language check and no local forms.",
    }.Where(s => s is not null));

    partial void OnReportChanged(ExpansionReport? value)
    {
        OnPropertyChanged(nameof(Summary));
        OnPropertyChanged(nameof(Missing));
        Fill();
    }

    partial void OnCandidatesOnlyChanged(bool value) => Fill();

    private void Fill()
    {
        Rows.Clear();
        foreach (var row in Report?.Rows ?? [])
            if (!CandidatesOnly || row.Candidate) Rows.Add(new ExpansionLine(row));
    }

    [RelayCommand(IncludeCancelCommand = true)]
    private async Task RunAsync(CancellationToken ct)
    {
        if (ChosenCountries.Count == 0) { Error = "Choose at least one storefront."; return; }
        Error = null;
        var progress = new Progress<ExpansionStep>(s => StepText = $"[{Math.Min(s.Completed + 1, s.Total)}/{s.Total}] {s.Country} · {s.Step}");
        try
        {
            Report = await client.ExpandAsync(App.TrackId, Market.Country, Market.Device, ChosenCountries, KeywordList, LocalForms, Track, progress, ct)
                .ConfigureAwait(true);
            if (Report.Tracked > 0) await tracked().ConfigureAwait(true);
        }
        catch (AsoCliException e)
        {
            Error = e.Message;
        }
        catch (OperationCanceledException)
        {
            Error = "Stopped. Cells measured before stopping were kept when Track was on.";
        }
        finally
        {
            StepText = null;
        }
    }
}
