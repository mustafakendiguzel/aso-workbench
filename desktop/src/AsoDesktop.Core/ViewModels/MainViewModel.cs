using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>
/// The window's workspace: tracked apps on the left; for the selected app its markets and Apple Ads genre (Overview),
/// and the selected market's keywords; research, metadata and settings beside them.
/// </summary>
public sealed partial class MainViewModel : ObservableObject
{
    /// <summary>"Any" in the genre picker: popularity searches every genre.</summary>
    public static readonly GenreInfo AnyGenre = new("any", "Any (search every genre)");

    private readonly AsoClient client;
    private bool showingGenre;

    public MainViewModel(AsoClient client)
    {
        this.client = client;
        Keywords = new KeywordsViewModel(client, Status);
        Research = new ResearchViewModel(client, Status);
        Metadata = new MetadataViewModel(client, Status);
        Settings = new SettingsViewModel(client, Status);
        Ratings = new RatingsViewModel(client, Status);
        Reviews = new ReviewsViewModel(client, Status);
        Competitors = new CompetitorsViewModel(client, Status);
        Changes = new ChangesViewModel(client, Status);
        Ads = new AdsViewModel(client, Status) { Synced = () => Keywords.Market is null ? Task.CompletedTask : Keywords.RefreshCommand.ExecuteAsync(null) };
        Keywords.MarketsChanged = KeywordsChangedAsync;
        Ratings.Checked = () => Status.QuietlyAsync(Changes.ReloadAsync);
        // Popularity can be read once the Apple Ads keys are stored, and not after they are removed.
        Settings.AppleAds.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(ConnectionViewModel.IsConfigured)) return;
            Keywords.AdsConnected = Settings.AppleAds.IsConfigured;
            Ads.AdsConnected = Settings.AppleAds.IsConfigured;
        };
    }

    public StatusViewModel Status { get; } = new();
    public KeywordsViewModel Keywords { get; }
    public ResearchViewModel Research { get; }
    public MetadataViewModel Metadata { get; }
    public SettingsViewModel Settings { get; }
    public RatingsViewModel Ratings { get; }
    public ReviewsViewModel Reviews { get; }
    public CompetitorsViewModel Competitors { get; }
    public ChangesViewModel Changes { get; }
    public AdsViewModel Ads { get; }

    public ObservableCollection<AppRecord> Apps { get; } = [];
    public ObservableCollection<MarketSummary> Markets { get; } = [];
    public ObservableCollection<StorefrontInfo> Storefronts { get; } = [];
    public ObservableCollection<GenreInfo> Genres { get; } = [];
    public static IReadOnlyList<string> Devices => KeywordsViewModel.Devices;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddMarketCommand))]
    public partial AppRecord? SelectedApp { get; set; }

    [ObservableProperty] public partial MarketSummary? SelectedMarket { get; set; }
    [ObservableProperty] public partial GenreInfo? SelectedGenre { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddMarketCommand))]
    public partial StorefrontInfo? NewMarketCountry { get; set; }

    [ObservableProperty] public partial string NewMarketDevice { get; set; } = "iphone";

    [ObservableProperty] public partial string? EngineVersion { get; set; }

    /// <summary>Where the engine keeps engine.sqlite, settings.json and credentials.json.</summary>
    [ObservableProperty] public partial string? DataDirectory { get; set; }

    /// <summary>Start-up: settings and connections, engine version, the pickers' lists and the apps; then, if the setting is on,
    /// the refresh of markets not measured recently.</summary>
    [RelayCommand]
    private async Task LoadAsync()
    {
        await Settings.LoadCommand.ExecuteAsync(null).ConfigureAwait(true);
        await Status.RunAsync("Loading tracked apps…", async () =>
        {
            var engine = await client.EngineInfoAsync().ConfigureAwait(true);
            EngineVersion = engine.Version;
            DataDirectory = engine.DataDirectory;
            Replace(Storefronts, await client.StorefrontsAsync().ConfigureAwait(true));
            Replace(Genres, [AnyGenre, .. await client.GenresAsync().ConfigureAwait(true)]);
            NewMarketCountry ??= Storefronts.FirstOrDefault(s => s.Code == "US") ?? Storefronts.FirstOrDefault();
            if (Settings.Current is { } settings) Keywords.Delta = settings.DeltaReference;
            await ReloadAppsAsync(keepSelection: null).ConfigureAwait(true);
            Status.Info(Apps.Count == 0 ? "No apps yet. Press Add app to start." : $"{Apps.Count} tracked app(s).");
        }).ConfigureAwait(true);
        if (Settings.Current?.AutoMeasureOnLaunch == true) await MeasureStaleCommand.ExecuteAsync(null).ConfigureAwait(true);
    }

    /// <summary>A fresh Add App dialog; the view shows it and hands the result to <see cref="AppAddedAsync"/>.</summary>
    public AddAppViewModel CreateAddApp() => new(client, Status, Storefronts, SelectedMarket?.Country ?? "US");

    /// <summary>A discovery dialog for the selected market, mining <paramref name="competitor"/>'s listing when given; null without a market.</summary>
    public DiscoveryViewModel? CreateDiscovery(Competitor? competitor = null) =>
        SelectedApp is { } app && SelectedMarket is { } market ? new DiscoveryViewModel(client, Status, app, market, competitor) : null;

    /// <summary>After the dialog added keywords: the table and the market counts.</summary>
    public async Task DiscoveryAddedAsync()
    {
        if (Keywords.Market is not null) await Keywords.RefreshCommand.ExecuteAsync(null).ConfigureAwait(true);
        await Status.QuietlyAsync(RefreshMarketsAsync).ConfigureAwait(true);
    }

    public Task AppAddedAsync(AppRecord app) => Status.RunAsync("Loading tracked apps…", async () =>
    {
        await ReloadAppsAsync(keepSelection: app.TrackId).ConfigureAwait(true);
        Status.Info($"Tracking {app.Name}.");
    });

    [RelayCommand]
    private Task RemoveAppAsync(AppRecord? app) => app is null ? Task.CompletedTask : Status.RunAsync($"Removing {app.Name}…", async () =>
    {
        await client.RemoveAppAsync(app.TrackId).ConfigureAwait(true);
        await ReloadAppsAsync(keepSelection: null).ConfigureAwait(true);
        Status.Info($"Removed {app.Name} with its keywords and measurements.");
    });

    private bool CanAddMarket() => SelectedApp is not null && NewMarketCountry is not null;

    [RelayCommand(CanExecute = nameof(CanAddMarket))]
    private Task AddMarketAsync() => SelectedApp is not { } app || NewMarketCountry is not { } country ? Task.CompletedTask :
        Status.RunAsync($"Adding the {country.Code} market…", async () =>
        {
            var market = await client.AddMarketAsync(app.TrackId, country.Code, NewMarketDevice).ConfigureAwait(true);
            await ReloadMarketsAsync(app, keep: market).ConfigureAwait(true);
            Status.Info($"Market {market.Title} ({market.CountryName}) is ready for keywords.");
        });

    [RelayCommand]
    private Task RemoveMarketAsync(MarketSummary? market) => SelectedApp is not { } app || market is null ? Task.CompletedTask :
        Status.RunAsync($"Removing the {market.Title} market…", async () =>
        {
            await client.RemoveMarketAsync(app.TrackId, market.Country, market.Device).ConfigureAwait(true);
            await ReloadMarketsAsync(app, keep: null).ConfigureAwait(true);
            Status.Info($"Removed the {market.Title} market with its keywords and measurements.");
        });

    /// <summary>Measures every market not measured within the stale-hours setting, as the macOS app does when it opens.</summary>
    [RelayCommand(IncludeCancelCommand = true)]
    private Task MeasureStaleAsync(CancellationToken cancellationToken) =>
        Status.RunAsync("Refreshing markets not measured recently…", async () =>
        {
            var progress = new Progress<MeasureStep>(step => Status.Info($"Refreshing {step.Completed}/{step.Total}: {step.Keyword} in {step.Market}"));
            var summary = await client.MeasureStaleAsync(progress, cancellationToken).ConfigureAwait(true);
            if (Keywords.Market is not null) await Keywords.RefreshCommand.ExecuteAsync(null).ConfigureAwait(true);
            await Competitors.LoadAsync().ConfigureAwait(true);
            await Changes.ReloadAsync().ConfigureAwait(true);
            Status.Info(summary.Measured == 0
                ? "Every market was measured recently."
                : $"Refreshed {summary.Measured} keyword(s): {summary.Found} ranked, {summary.Outside} outside, {summary.Failed} failed.");
        });

    partial void OnSelectedAppChanged(AppRecord? oldValue, AppRecord? newValue)
    {
        Keywords.App = newValue;
        Ratings.App = newValue;
        Reviews.App = newValue;
        Competitors.App = newValue;
        Changes.App = newValue;
        Ads.App = newValue;
        ShowGenre(newValue);
        if (oldValue?.TrackId == newValue?.TrackId) return;   // the same app with refreshed details: keep its markets
        Markets.Clear();
        SelectedMarket = null;
        if (newValue is not null) _ = Status.RunAsync("Loading markets…", () => ReloadMarketsAsync(newValue, keep: null));
    }

    partial void OnSelectedMarketChanged(MarketSummary? oldValue, MarketSummary? newValue)
    {
        Keywords.Market = newValue;
        Competitors.Market = newValue;
        if (newValue is not null && !KeywordsViewModel.SameMarket(oldValue, newValue)) Keywords.RefreshCommand.Execute(null);
    }

    partial void OnSelectedGenreChanged(GenreInfo? value)
    {
        if (showingGenre || value is null || SelectedApp is not { } app) return;
        var genre = value == AnyGenre ? null : value.Id;
        if (genre == app.AdsGenre) return;
        _ = Status.RunAsync("Saving the Apple Ads genre…", async () =>
        {
            var updated = await client.SetAdsGenreAsync(app.TrackId, genre).ConfigureAwait(true);
            var index = Apps.IndexOf(app);
            if (index >= 0) Apps[index] = updated;
            if (SelectedApp?.TrackId == updated.TrackId) SelectedApp = updated;
            Status.Info($"Apple Ads genre: {value.Name}.");
        });
    }

    /// <summary>Keeps the market list in step after keywords were added or measured.</summary>
    public Task RefreshMarketsAsync() => SelectedApp is { } app ? ReloadMarketsAsync(app, keep: SelectedMarket) : Task.CompletedTask;

    /// <summary>After keywords were added, removed or measured: market counts, and what a measurement also read (ratings, new
    /// reviews, the results competitors come from, a release recorded before measuring and the ranks around each marker).</summary>
    private async Task KeywordsChangedAsync()
    {
        await RefreshMarketsAsync().ConfigureAwait(true);
        await Status.QuietlyAsync(Ratings.ReloadAsync).ConfigureAwait(true);
        await Status.QuietlyAsync(Reviews.ReloadAsync).ConfigureAwait(true);
        await Status.QuietlyAsync(Competitors.LoadAsync).ConfigureAwait(true);
        await Status.QuietlyAsync(Changes.ReloadAsync).ConfigureAwait(true);
    }

    private void ShowGenre(AppRecord? app)
    {
        showingGenre = true;
        SelectedGenre = app is null ? null : Genres.FirstOrDefault(g => g.Id == app.AdsGenre) ?? AnyGenre;
        showingGenre = false;
    }

    private async Task ReloadAppsAsync(long? keepSelection)
    {
        var selected = keepSelection ?? SelectedApp?.TrackId;
        Replace(Apps, await client.ListAppsAsync().ConfigureAwait(true));
        SelectedApp = Apps.FirstOrDefault(a => a.TrackId == selected) ?? Apps.FirstOrDefault();
    }

    private async Task ReloadMarketsAsync(AppRecord app, MarketSummary? keep)
    {
        var markets = await client.MarketsAsync(app.TrackId).ConfigureAwait(true);
        if (SelectedApp?.TrackId != app.TrackId) return;   // the selection moved on while loading
        var previous = keep ?? SelectedMarket;
        Replace(Markets, markets);
        SelectedMarket = Markets.FirstOrDefault(m => m.Country == previous?.Country && m.Device == previous?.Device) ?? Markets.FirstOrDefault();
    }

    private static void Replace<T>(ObservableCollection<T> target, IEnumerable<T> items)
    {
        target.Clear();
        foreach (var item in items) target.Add(item);
    }
}
