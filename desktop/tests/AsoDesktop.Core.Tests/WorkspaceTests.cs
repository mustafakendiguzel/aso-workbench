using System.Globalization;
using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class MainViewModelTests
{
    /// <summary>Start-up commands answered from fixtures; everything else by <paramref name="byCommand"/>.</summary>
    internal static (MainViewModel, FakeCli) Make(Func<string, CliResult> byCommand)
    {
        var cli = new FakeCli();
        cli.Respond = args => args.Contains("--version") ? FakeCli.Fixture("version") : FakeCli.Command(args) switch
        {
            "settings" => FakeCli.Fixture("settings"),
            "connections" => FakeCli.Fixture("connections"),
            "storefronts" => FakeCli.Fixture("storefronts"),
            "genres" => FakeCli.Fixture("genres"),
            var command => byCommand(command),
        };
        return (new MainViewModel(new AsoClient(cli)), cli);
    }

    [Fact]
    public async Task LoadingSelectsTheFirstAppAndMarketAndLoadsThatMarketsKeywords()
    {
        var (vm, cli) = Make(command => command switch
        {
            "app list" => FakeCli.Fixture("app-list"),
            "market list" => FakeCli.Fixture("market-list"),
            "keywords list" => FakeCli.Fixture("keywords-list"),
            "ratings list" => FakeCli.Fixture("ratings-list"),
            "reviews list" => FakeCli.Fixture("reviews-list"),
            "competitors" => FakeCli.Fixture("competitors"),
            _ => throw new InvalidOperationException(command),
        });
        await vm.LoadCommand.ExecuteAsync(null);

        Assert.Equal("1.0.0", vm.EngineVersion);
        Assert.Equal(51, vm.Storefronts.Count);   // every country the engine knows, from the fixture
        Assert.Equal(MainViewModel.AnyGenre, vm.Genres[0]);
        Assert.Equal(361285480, Assert.Single(vm.Apps).TrackId);
        Assert.Equal(["TR · iphone", "US · iphone"], vm.Markets.Select(m => m.Title));
        Assert.Equal("Türkiye", vm.Markets[0].CountryName);
        Assert.Equal("TR · iphone", vm.SelectedMarket?.Title);
        Assert.Same(vm.SelectedMarket, vm.Keywords.Market);
        Assert.Equal("PRODUCTIVITY_UTILITIES", vm.SelectedGenre?.Id);
        Assert.Equal("lastMarker", vm.Keywords.Delta);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "keywords", "list", "361285480", "--country", "TR", "--device", "iphone", "--delta", "lastMarker"]));
        // The app's ratings and reviews, and the selected market's competitors, follow the selection.
        Assert.Equal(2, vm.Ratings.Rows.Count);
        Assert.Equal(3, vm.Reviews.Visible.Count);
        Assert.Same(vm.SelectedMarket, vm.Competitors.Market);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "competitors", "361285480", "--country", "TR", "--device", "iphone", "--depth", "10"]));
        Assert.False(vm.Status.IsError);
    }

    [Fact]
    public async Task ChangingTheGenreSavesItAndKeepsTheMarket()
    {
        var education = FakeCli.Fixture("app-add").Output.Replace("PRODUCTIVITY_UTILITIES", "EDUCATION", StringComparison.Ordinal);
        var (vm, cli) = Make(command => command switch
        {
            "app list" => FakeCli.Fixture("app-list"),
            "market list" => FakeCli.Fixture("market-list"),
            "app genre" => FakeCli.Ok(education),
            _ => FakeCli.Ok("[]"),
        });
        await vm.LoadCommand.ExecuteAsync(null);
        vm.SelectedMarket = vm.Markets[1];
        vm.SelectedGenre = vm.Genres.First(g => g.Id == "EDUCATION");

        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "app", "genre", "361285480", "EDUCATION"]));
        Assert.Equal("EDUCATION", vm.SelectedApp?.AdsGenre);
        Assert.Equal("US · iphone", vm.SelectedMarket?.Title);

        vm.SelectedGenre = MainViewModel.AnyGenre;
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "app", "genre", "361285480", "any"]));
    }

    [Fact]
    public async Task AddingAndRemovingMarkets()
    {
        var (vm, cli) = Make(command => command switch
        {
            "app list" => FakeCli.Fixture("app-list"),
            "market list" => FakeCli.Fixture("market-list"),
            "market add" => FakeCli.Ok("""{"country":"US","countryName":"United States","device":"iphone","keywords":1}"""),
            _ => FakeCli.Ok("{}"),
        });
        await vm.LoadCommand.ExecuteAsync(null);
        vm.NewMarketCountry = vm.Storefronts.First(s => s.Code == "US");
        await vm.AddMarketCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "market", "add", "361285480", "--country", "US", "--device", "iphone"]));
        Assert.Equal("US · iphone", vm.SelectedMarket?.Title);

        await vm.RemoveMarketCommand.ExecuteAsync(vm.Markets[0]);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "market", "remove", "361285480", "--country", "TR", "--device", "iphone"]));
    }

    [Fact]
    public async Task AnAppAddedInTheDialogIsSelected()
    {
        var (vm, _) = Make(command => command switch
        {
            "app list" => FakeCli.Fixture("app-list"),
            "market list" => FakeCli.Fixture("market-list"),
            _ => FakeCli.Ok("[]"),
        });
        await vm.AppAddedAsync(new AppRecord(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch));
        Assert.Equal(361285480, vm.SelectedApp?.TrackId);
        Assert.Equal("Tracking Keynote.", vm.Status.Message);
    }

    [Fact]
    public async Task EngineErrorsLandInTheStatusLine()
    {
        var (vm, _) = Make(_ => new CliResult(1, "", "error: App 42 is not tracked. Add it first.\n"));
        await vm.LoadCommand.ExecuteAsync(null);
        Assert.True(vm.Status.IsError);
        Assert.Equal("App 42 is not tracked. Add it first.", vm.Status.Message);
        Assert.False(vm.Status.IsBusy);
    }

    [Fact]
    public async Task RemovingAnAppReloadsTheList()
    {
        var removed = false;
        CliResult Remove()
        {
            removed = true;
            return FakeCli.Ok("""{"removed":361285480}""");
        }
        var (vm, _) = Make(command => command switch
        {
            "app remove" => Remove(),
            "app list" => removed ? FakeCli.Ok("[]") : FakeCli.Fixture("app-list"),
            "market list" => FakeCli.Fixture("market-list"),
            _ => FakeCli.Ok("[]"),
        });
        await vm.LoadCommand.ExecuteAsync(null);
        await vm.RemoveAppCommand.ExecuteAsync(vm.SelectedApp);
        Assert.Empty(vm.Apps);
        Assert.Null(vm.SelectedApp);
        Assert.Empty(vm.Markets);
        Assert.Null(vm.Keywords.Market);
    }
}

public sealed class AddAppViewModelTests
{
    private static readonly IReadOnlyList<StorefrontInfo> Storefronts =
        [new("DE", "Germany", "de-DE"), new("TR", "Türkiye", "tr"), new("US", "United States", "en-US")];

    [Fact]
    public async Task SearchFillsResultsAndAddingSendsDeviceAndMarkets()
    {
        var cli = new FakeCli { Respond = args => FakeCli.Fixture(FakeCli.Command(args) == "app search" ? "app-search" : "app-add") };
        var vm = new AddAppViewModel(new AsoClient(cli), new StatusViewModel(), Storefronts, "TR");
        Assert.Equal(["TR"], vm.SelectedCountries);
        Assert.False(vm.SearchCommand.CanExecute(null));
        Assert.False(vm.AddCommand.CanExecute(null));

        vm.Query = "keynote";
        await vm.SearchCommand.ExecuteAsync(null);
        Assert.Equal(["--json", "app", "search", "--country", "TR", "--", "keynote"], cli.Calls[0]);
        Assert.NotEmpty(vm.Results);
        Assert.Same(vm.Results[0], vm.SelectedResult);
        Assert.True(vm.AddCommand.CanExecute(null));

        vm.Countries[0].IsSelected = true;   // DE
        vm.Countries[1].IsSelected = false;  // TR
        vm.Countries[2].IsSelected = true;   // US
        vm.Device = "ipad";
        await vm.AddCommand.ExecuteAsync(null);
        Assert.Equal(["--json", "app", "add", vm.Results[0].TrackId.ToString(CultureInfo.InvariantCulture),
                      "--country", "TR", "--markets", "DE,US", "--device", "ipad"], cli.Calls[1]);
        Assert.Equal(361285480, vm.Added?.TrackId);
    }

    [Fact]
    public void AddingNeedsAtLeastOneMarket()
    {
        var vm = new AddAppViewModel(new AsoClient(new FakeCli()), new StatusViewModel(), Storefronts, "US")
        {
            SelectedResult = new SearchResultApp(1, "App", "Seller", null, null, null, null),
        };
        Assert.True(vm.AddCommand.CanExecute(null));
        vm.Countries[2].IsSelected = false;
        Assert.False(vm.AddCommand.CanExecute(null));
    }
}

public sealed class KeywordsViewModelTests
{
    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);
    private static readonly MarketSummary Us = new("US", "United States", "iphone", 2, null);

    private static (KeywordsViewModel, FakeCli, StatusViewModel) Make(Func<string, CliResult> byCommand)
    {
        var cli = new FakeCli();
        cli.Respond = args => byCommand(FakeCli.Command(args));
        var status = new StatusViewModel();
        return (new KeywordsViewModel(new AsoClient(cli), status) { App = App, Market = Us }, cli, status);
    }

    [Fact]
    public void KeywordsAreSplitByLineOrCommaWithoutBlanksOrRepeats()
    {
        // The text is kept as typed; the engine normalizes it when it stores the keyword.
        Assert.Equal(["budget planner", "Expense tracker", "savings"],
                     KeywordsViewModel.ParseKeywords("budget planner\r\n Expense tracker, ,savings\nBUDGET PLANNER\n"));
        Assert.Empty(KeywordsViewModel.ParseKeywords(" ,\n "));
    }

    [Fact]
    public async Task AddingKeywordsGoesToTheSelectedMarketAndUpdatesMarkets()
    {
        var (vm, cli, status) = Make(command => command == "keywords add" ? FakeCli.Fixture("keywords-add") : FakeCli.Fixture("keywords-list"));
        var marketsChanged = 0;
        vm.MarketsChanged = () => { marketsChanged++; return Task.CompletedTask; };
        vm.NewKeywords = "presentation\nslides maker";
        await vm.AddKeywordsCommand.ExecuteAsync(null);

        Assert.Equal(["--json", "keywords", "add", "361285480", "--country", "US", "--device", "iphone", "--", "presentation", "slides maker"],
                     cli.Calls[0]);
        Assert.Equal("", vm.NewKeywords);
        Assert.Equal(2, vm.Rows.Count);
        Assert.Equal(1, marketsChanged);
        Assert.Equal("Added 2 keyword(s) in US · iphone.", status.Message);
    }

    [Fact]
    public async Task MeasuringCoversTheSelectedMarket()
    {
        var (vm, cli, status) = Make(command => command == "measure" ? FakeCli.Fixture("measure") : FakeCli.Fixture("keywords-list"));
        await vm.MeasureCommand.ExecuteAsync(null);
        Assert.Equal("Measured 2: 1 ranked, 1 outside the results, 0 failed.", status.Message);
        Assert.Null(vm.MeasureStepText);
        Assert.Equal(["--json", "measure", "361285480", "--country", "US", "--device", "iphone"], cli.Calls[0]);
    }

    [Fact]
    public void ProgressStepsMoveTheBar()
    {
        var (vm, _, _) = Make(_ => FakeCli.Ok("[]"));
        vm.ShowStep(new MeasureStep(1, 4, "US · iphone", "notes", "#2", "found"));
        Assert.Equal(0.25, vm.MeasureFraction);
        Assert.Equal("1/4  notes  #2", vm.MeasureStepText);
    }

    [Fact]
    public async Task RowsFormatEngineValuesWithoutInventingAny()
    {
        var (vm, _, _) = Make(_ => FakeCli.Fixture("keywords-list"));
        await vm.RefreshCommand.ExecuteAsync(null);
        var found = vm.Rows[0];
        var outside = vm.Rows[1];
        Assert.Equal(("#3", 3, "57", ""), (found.Rank, found.RankOrder, found.Difficulty, found.Brand));
        Assert.Equal(("> 179", 180, "58", "brand"), (outside.Rank, outside.RankOrder, outside.Difficulty, outside.Brand));
        Assert.Equal("", outside.Delta);
        Assert.NotEqual("never", outside.Measured);

        var row = new KeywordRow(found.Report with { Delta = 7, MeasuredAt = null, Rank = null, ObservedCount = null });
        Assert.Equal(("+7", "never", int.MaxValue), (row.Delta, row.Measured, row.RankOrder));
    }

    [Fact]
    public async Task ANewMarketClearsRowsButARefreshedCountDoesNot()
    {
        var (vm, _, _) = Make(_ => FakeCli.Fixture("keywords-list"));
        await vm.RefreshCommand.ExecuteAsync(null);
        vm.Market = Us with { Keywords = 3 };
        Assert.Equal(2, vm.Rows.Count);
        vm.Market = new MarketSummary("DE", "Germany", "iphone", 0, null);
        Assert.Empty(vm.Rows);
        vm.App = null;
        Assert.Null(vm.Market);
        Assert.False(vm.MeasureCommand.CanExecute(null));
    }
}
