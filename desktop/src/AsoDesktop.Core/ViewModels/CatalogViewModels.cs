using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>"3 hours ago", "yesterday": the macOS app's relative dates, from a given moment so tests can fix it.</summary>
public static class RelativeTime
{
    public static string Format(DateTimeOffset at, DateTimeOffset now)
    {
        var elapsed = now - at;
        if (elapsed < TimeSpan.FromMinutes(1)) return "just now";
        if (elapsed < TimeSpan.FromHours(1)) return Plural((int)elapsed.TotalMinutes, "minute");
        if (elapsed < TimeSpan.FromDays(1)) return Plural((int)elapsed.TotalHours, "hour");
        if (elapsed < TimeSpan.FromDays(2)) return "yesterday";
        if (elapsed < TimeSpan.FromDays(30)) return Plural((int)elapsed.TotalDays, "day");
        return at.ToLocalTime().ToString("d", CultureInfo.CurrentCulture);
    }

    private static string Plural(int n, string unit) => n == 1 ? $"1 {unit} ago" : $"{n} {unit}s ago";
}

/// <summary>A storefront's ratings as the Overview's table shows them.</summary>
public sealed record RatingLine(RatingRow Row, DateTimeOffset Now)
{
    public string Storefront => Row.Title;
    public string Count => Row.Count.ToString("N0", CultureInfo.CurrentCulture);
    public string Average => Row.Average is { } a ? a.ToString("0.00", CultureInfo.CurrentCulture) : "—";
    public string SinceLastCheck => Row.Delta switch
    {
        null => "first check",
        0 => "—",
        var d => d.Value.ToString("+0;-0", CultureInfo.CurrentCulture),
    };
    public string LastNewRating => Row.LastNewAt is { } at ? RelativeTime.Format(at, Now) : "—";
    public string Checked => RelativeTime.Format(Row.CheckedAt, Now);
}

/// <summary>The Overview's ratings card: ratings per storefront, where the latest new rating came from, and the latest written
/// review. Ratings and reviews are read when the market is measured; Check reads them now.</summary>
public sealed partial class RatingsViewModel(AsoClient client, StatusViewModel status, Func<DateTimeOffset>? clock = null) : ObservableObject
{
    private readonly Func<DateTimeOffset> now = clock ?? (() => DateTimeOffset.Now);

    public ObservableCollection<RatingLine> Rows { get; } = [];

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(CheckCommand))]
    public partial AppRecord? App { get; set; }

    [ObservableProperty] public partial string Headline { get; set; } = "";
    [ObservableProperty] public partial string? LatestReview { get; set; }
    [ObservableProperty] public partial bool HasRows { get; set; }

    /// <summary>Runs after a check: the same lookups record a new App Store release.</summary>
    public Func<Task>? Checked { get; set; }

    partial void OnAppChanged(AppRecord? oldValue, AppRecord? newValue)
    {
        if (oldValue?.TrackId == newValue?.TrackId) return;
        Rows.Clear();
        HasRows = false;
        Headline = "";
        LatestReview = null;
        if (newValue is not null) _ = status.QuietlyAsync(ReloadAsync);
    }

    public async Task ReloadAsync()
    {
        if (App is not { } app) return;
        var ratings = await client.RatingsAsync(app.TrackId).ConfigureAwait(true);
        var reviews = await client.ReviewsAsync(app.TrackId).ConfigureAwait(true);
        if (App?.TrackId != app.TrackId) return;   // the selection moved on while loading
        var at = now();
        Rows.Clear();
        foreach (var row in ratings) Rows.Add(new RatingLine(row, at));
        HasRows = Rows.Count > 0;
        Headline = HeadlineFor(ratings, at);
        LatestReview = reviews.Reviews.Count > 0 && reviews.Reviews[0] is { } r
            ? $"Latest written review: {r.Country} · {r.Rating}★ “{r.Title}” · {RelativeTime.Format(r.Date ?? r.FetchedAt, at)}: {reviews.Stored} stored, see Reviews."
            : null;
    }

    internal static string HeadlineFor(IReadOnlyList<RatingRow> rows, DateTimeOffset now)
    {
        if (rows.Where(r => r.LastNewAt is not null).MaxBy(r => r.LastNewAt) is { } latest)
            return $"Last new rating: {latest.CountryName} · {RelativeTime.Format(latest.LastNewAt!.Value, now)}";
        if (rows.Count == 0)
            return "No ratings recorded yet. Ratings are read from the App Store for every tracked storefront when you measure; press Check to read them now.";
        return $"No new rating seen between checks yet ({rows.Count} storefront(s), {rows.Sum(r => r.Count).ToString("N0", CultureInfo.CurrentCulture)} ratings in total).";
    }

    /// <param name="everyStorefront">"all" reads every App Store country; anything else the app's markets.</param>
    [RelayCommand(CanExecute = nameof(HasApp))]
    private Task CheckAsync(string? everyStorefront) => App is not { } app ? Task.CompletedTask : status.RunAsync("Reading ratings…", async () =>
    {
        var check = await client.CheckRatingsAsync(app.TrackId, everyStorefront == "all").ConfigureAwait(true);
        await ReloadAsync().ConfigureAwait(true);
        status.Info($"Checked {check.Storefronts} storefront(s): {check.NewRatings} new rating(s) since the previous check."
                    + (check.Failed.Count == 0 ? "" : $" Failed: {string.Join(", ", check.Failed)}.")
                    + (check.NewRelease is { } release ? $" New release: {release.Title}." : ""));
        if (Checked is { } after) await after().ConfigureAwait(true);
    });

    private bool HasApp() => App is not null;
}

/// <summary>A stored review as the list shows it.</summary>
public sealed record ReviewLine(StoredReview Review)
{
    public string Stars => new string('★', Math.Clamp(Review.Rating, 0, 5)) + new string('☆', 5 - Math.Clamp(Review.Rating, 0, 5));
    /// <summary>For the stars' colour: good is four or five stars, bad one or two, mixed three.</summary>
    public bool IsGood => Review.Rating >= 4;
    public bool IsBad => Review.Rating <= 2;
    public bool IsMixed => Review.Rating == 3;
    public string Byline => string.Join(" · ", new[]
    {
        Review.Author,
        Review.Version is { } v ? $"v{v}" : "",
        Review.Country,
        (Review.Date ?? Review.FetchedAt).ToLocalTime().ToString("g", CultureInfo.CurrentCulture),
    }.Where(part => part.Length > 0));
}

/// <summary>Written reviews across the app's storefronts, newest first, with what arrived since the previous check.</summary>
public sealed partial class ReviewsViewModel(AsoClient client, StatusViewModel status) : ObservableObject
{
    /// <summary>"All storefronts" in the storefront filter.</summary>
    public const string AllStorefronts = "All storefronts";

    public static IReadOnlyList<int> MinimumRatings { get; } = [1, 2, 3, 4, 5];

    private IReadOnlyList<StoredReview> all = [];

    public ObservableCollection<ReviewLine> Visible { get; } = [];
    public ObservableCollection<string> Countries { get; } = [AllStorefronts];

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(CheckCommand))]
    public partial AppRecord? App { get; set; }

    [ObservableProperty] public partial string Country { get; set; } = AllStorefronts;
    [ObservableProperty] public partial int MinRating { get; set; } = 1;
    [ObservableProperty] public partial bool OnlyNew { get; set; }
    [ObservableProperty] public partial string Search { get; set; } = "";
    [ObservableProperty] public partial ReviewsReport? Report { get; set; }

    public bool IsEmpty => Report is null || Report.Stored == 0;

    public string Summary => Report is { } r ? $"{r.Stored} stored · {r.New} new" : "";

    /// <summary>Stored reviews per star, five first, and the average.</summary>
    public string StarCounts => Report is not { } r ? "" :
        string.Join("  ", Enumerable.Range(1, 5).Reverse().Select(s => $"{s}★ {(r.Stars.Count >= s ? r.Stars[s - 1] : 0)}"))
        + (r.Average is { } a ? "  avg " + a.ToString("0.0", CultureInfo.CurrentCulture) : "");

    /// <summary>The engine's review filters: storefront, minimum rating, new only, a text in the title or body.</summary>
    public bool Allows(StoredReview review) =>
        (Country == AllStorefronts || review.Country == Country)
        && review.Rating >= MinRating
        && (!OnlyNew || review.IsNew)
        // Ordinal: a culture-aware comparison breaks under Turkish casing.
        && (Search.Trim().Length == 0 || review.Title.Contains(Search.Trim(), StringComparison.OrdinalIgnoreCase)
                                       || review.Body.Contains(Search.Trim(), StringComparison.OrdinalIgnoreCase));

    partial void OnCountryChanged(string value) => ApplyFilters();
    partial void OnMinRatingChanged(int value) => ApplyFilters();
    partial void OnOnlyNewChanged(bool value) => ApplyFilters();
    partial void OnSearchChanged(string value) => ApplyFilters();

    partial void OnReportChanged(ReviewsReport? value)
    {
        all = value?.Reviews ?? [];
        var keep = Country;
        Countries.Clear();
        Countries.Add(AllStorefronts);
        foreach (var country in value?.Countries ?? []) Countries.Add(country);
        Country = Countries.Contains(keep) ? keep : AllStorefronts;
        ApplyFilters();
        OnPropertyChanged(nameof(IsEmpty));
        OnPropertyChanged(nameof(Summary));
        OnPropertyChanged(nameof(StarCounts));
    }

    partial void OnAppChanged(AppRecord? oldValue, AppRecord? newValue)
    {
        if (oldValue?.TrackId == newValue?.TrackId) return;
        Report = null;
        if (newValue is not null) _ = status.QuietlyAsync(ReloadAsync);
    }

    public async Task ReloadAsync()
    {
        if (App is not { } app) return;
        var report = await client.ReviewsAsync(app.TrackId).ConfigureAwait(true);
        if (App?.TrackId == app.TrackId) Report = report;
    }

    /// <param name="everyStorefront">"all" reads every App Store country; anything else the app's markets.</param>
    [RelayCommand(CanExecute = nameof(HasApp))]
    private Task CheckAsync(string? everyStorefront) => App is not { } app ? Task.CompletedTask : status.RunAsync("Reading reviews…", async () =>
    {
        var check = await client.CheckReviewsAsync(app.TrackId, everyStorefront == "all").ConfigureAwait(true);
        await ReloadAsync().ConfigureAwait(true);
        status.Info($"Checked {check.Storefronts} storefront(s): {check.Added} new review(s), {check.Stored} stored."
                    + (check.Failed.Count == 0 ? "" : $" Failed: {string.Join(", ", check.Failed)}."));
    });

    [RelayCommand]
    private void ClearFilters()
    {
        Country = AllStorefronts;
        MinRating = 1;
        OnlyNew = false;
        Search = "";
    }

    private bool HasApp() => App is not null;

    private void ApplyFilters()
    {
        Visible.Clear();
        foreach (var review in all.Where(Allows)) Visible.Add(new ReviewLine(review));
    }
}

/// <summary>A competitor as the table shows it.</summary>
public sealed record CompetitorLine(Competitor App)
{
    public string Name => App.Name;
    public string Seller => App.SellerName;
    public int Keywords => App.Keywords;
    public int Top10 => App.Top10;
    public string AveragePosition => App.AveragePosition.ToString("0.0", CultureInfo.CurrentCulture);
    public string Ratings => (App.RatingCount ?? 0).ToString("N0", CultureInfo.CurrentCulture);
    public int RatingsOrder => App.RatingCount ?? 0;
    public string Rating => App.AverageRating is { } r ? r.ToString("0.0", CultureInfo.CurrentCulture) : "—";
    public string Details => $"{App.SellerName} · {App.PrimaryGenre ?? "—"}";
    public string Identifiers => $"App ID {App.TrackId}" + (App.BundleId is { } b ? $" · {b}" : "");
    public string? LastUpdate => App.CurrentVersionReleaseDate?.ToLocalTime().ToString("d", CultureInfo.CurrentCulture);
    public IEnumerable<CompetitorAppearance> Appearances => App.Appearances;
}

/// <summary>Competitors as observed in the market's tracked searches; deliberately not "every keyword of app X".</summary>
public sealed partial class CompetitorsViewModel(AsoClient client, StatusViewModel status) : ObservableObject
{
    public static IReadOnlyList<int> Depths { get; } = [5, 10, 20, 50];

    public ObservableCollection<CompetitorLine> Rows { get; } = [];

    [ObservableProperty] public partial AppRecord? App { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(RefreshCommand))]
    public partial MarketSummary? Market { get; set; }

    [ObservableProperty] public partial int Depth { get; set; } = 10;
    [ObservableProperty] public partial CompetitorsReport? Report { get; set; }
    [ObservableProperty] public partial CompetitorLine? Selected { get; set; }

    public bool HasMeasurements => Report is { KeywordsMeasured: > 0 };

    public string Headline => Report is not { } r ? "" : r.KeywordsMeasured == 0
        ? "No measurements yet. Measure keywords first: competitors are the apps that appear in those search results."
        : $"Apps seen in the top {r.Depth} of your {r.KeywordsMeasured} measured keyword(s) in {r.Market}";

    partial void OnDepthChanged(int value) => Reload();
    partial void OnMarketChanged(MarketSummary? oldValue, MarketSummary? newValue)
    {
        if (!KeywordsViewModel.SameMarket(oldValue, newValue)) Reload();
    }

    partial void OnReportChanged(CompetitorsReport? value)
    {
        var keep = Selected?.App.TrackId;
        Rows.Clear();
        foreach (var competitor in value?.Competitors ?? []) Rows.Add(new CompetitorLine(competitor));
        Selected = Rows.FirstOrDefault(r => r.App.TrackId == keep);
        OnPropertyChanged(nameof(HasMeasurements));
        OnPropertyChanged(nameof(Headline));
    }

    private void Reload()
    {
        if (Market is null) Report = null;
        else _ = status.QuietlyAsync(LoadAsync);
    }

    /// <summary>Reads the list again, after a measurement or when the market or depth changes.</summary>
    public async Task LoadAsync()
    {
        if (App is not { } app || Market is not { } market) return;
        var depth = Depth;
        var report = await client.CompetitorsAsync(app.TrackId, market.Country, market.Device, depth).ConfigureAwait(true);
        // The selection or depth moved on while loading: a newer load brings the right list.
        if (App?.TrackId == app.TrackId && KeywordsViewModel.SameMarket(Market, market) && Depth == depth) Report = report;
    }

    private bool HasMarket() => Market is not null;

    [RelayCommand(CanExecute = nameof(HasMarket))]
    private Task RefreshAsync() => Market is not { } market ? Task.CompletedTask : status.RunAsync("Loading competitors…", async () =>
    {
        await LoadAsync().ConfigureAwait(true);
        status.Info(Report is { KeywordsMeasured: > 0 } r ? $"{r.Competitors.Count} competitor(s) in {market.Title}." : $"No measurements yet in {market.Title}.");
    });
}
