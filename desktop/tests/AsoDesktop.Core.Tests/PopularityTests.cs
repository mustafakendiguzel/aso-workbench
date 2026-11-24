using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class PopularityContractTests
{
    // keywords-popularity.json is the real engine's output over two seeded readings (reading Apple's lists needs keys):
    // "presentation" on the list with 61, "slides maker" below it, under 31. popularity.json has the shape of
    // `aso popularity --json`, which the engine's own tests pin.
    private static AsoClient Client(string fixture) => new(new FakeCli { Respond = _ => FakeCli.Fixture(fixture) });

    [Fact]
    public async Task ReadingsAreReadWithTheirSource()
    {
        var rows = await Client("keywords-popularity").ListKeywordsAsync(1, ct: TestContext.Current.CancellationToken);
        var presentation = rows[0];
        Assert.Equal(61, presentation.Popularity);
        Assert.Equal("list", presentation.PopularitySource);
        Assert.Equal("PRODUCTIVITY_UTILITIES", presentation.PopularityGenre);
        Assert.Equal(new DateTimeOffset(2026, 9, 1, 0, 0, 0, TimeSpan.Zero), presentation.PopularityMonth);
        Assert.Equal("61", presentation.PopularityLabel);
        Assert.NotNull(presentation.Opportunity);

        var slides = rows[1];
        Assert.Null(slides.Popularity);   // below the published range: no number is made up
        Assert.Equal(("belowRange", 31), (slides.PopularitySource, slides.PopularityBelow));
        Assert.Equal("< 31", slides.PopularityLabel);
        Assert.Null(slides.Opportunity);
    }

    [Fact]
    public async Task KeywordsWithoutReadingsHaveNoLabel()
    {
        var rows = await Client("keywords-list").ListKeywordsAsync(1, ct: TestContext.Current.CancellationToken);
        Assert.All(rows, row => Assert.Equal("", row.PopularityLabel));
        Assert.All(rows, row => Assert.Null(row.PopularityMonth));
    }

    [Fact]
    public async Task RefreshesAreReadAndArgumentsBuilt()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("popularity") };
        var client = new AsoClient(cli);
        var ct = TestContext.Current.CancellationToken;
        var refresh = Assert.Single(await client.PopularityAsync(7, "US", "iphone", ct: ct));
        Assert.Equal((2, 1, 1, 31), (refresh.Keywords, refresh.OnList, refresh.BelowRange, refresh.Floor));
        Assert.Empty(refresh.GenresFound);
        await client.PopularityAsync(7, "US", "ipad", ["notes", "slides maker"], ct);
        Assert.Equal(["--json", "popularity", "7", "--country", "US", "--device", "iphone"], cli.Calls[0]);
        Assert.Equal(["--json", "popularity", "7", "--country", "US", "--device", "ipad", "--keywords", "notes,slides maker"], cli.Calls[1]);
    }

    [Fact]
    public async Task MeasurementsCarryTheirPopularityRefresh()
    {
        var plain = await Client("measure").MeasureAsync(1, ct: TestContext.Current.CancellationToken);
        Assert.Null(plain.Popularity);
        Assert.Null(plain.PopularityError);

        var client = new AsoClient(new FakeCli
        {
            Respond = _ => FakeCli.Ok("""
                {"measured":2,"found":1,"outside":1,"failed":0,"popularityError":"Apple Ads rejected the credentials (401/403).",
                 "popularity":[{"country":"US","periodStart":"2026-09-01T00:00:00Z","periodEnd":"2026-09-30T00:00:00Z",
                                "keywords":2,"onList":2,"belowRange":0,"genresFound":["Education"]}]}
                """),
        });
        var summary = await client.MeasureAsync(1, ct: TestContext.Current.CancellationToken);
        Assert.Equal(2, Assert.Single(summary.Popularity!).OnList);
        Assert.Null(summary.Popularity![0].Genre);   // every genre was searched
        Assert.Equal(["Education"], summary.Popularity[0].GenresFound);
        Assert.Equal("Apple Ads rejected the credentials (401/403).", summary.PopularityError);
    }
}

public sealed class PopularityViewModelTests
{
    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);
    private static readonly MarketSummary Us = new("US", "United States", "iphone", 2, null);

    private static (KeywordsViewModel, FakeCli, StatusViewModel) Make()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Fixture(FakeCli.Command(args) == "popularity" ? "popularity" : "keywords-popularity");
        var status = new StatusViewModel();
        return (new KeywordsViewModel(new AsoClient(cli), status) { App = App, Market = Us }, cli, status);
    }

    [Fact]
    public async Task RefreshNeedsAppleAdsAndReloadsTheTable()
    {
        var (vm, cli, status) = Make();
        Assert.False(vm.RefreshPopularityCommand.CanExecute(null));
        vm.AdsConnected = true;
        Assert.True(vm.RefreshPopularityCommand.CanExecute(null));
        Assert.False(vm.RefreshPopularitySelectedCommand.CanExecute(null));   // nothing selected

        var marketsChanged = 0;
        vm.MarketsChanged = () => { marketsChanged++; return Task.CompletedTask; };
        await vm.RefreshPopularityCommand.ExecuteAsync(null);
        Assert.Equal(["--json", "popularity", "361285480", "--country", "US", "--device", "iphone"], cli.Calls[0]);
        Assert.Equal("US: 1 of 2 keyword(s) on Apple's list (September 2026); 1 below the published range (under 31).", status.Message);
        Assert.Equal(["61", "< 31"], vm.Rows.Select(r => r.Popularity));
        Assert.Equal(1, marketsChanged);   // the Changes report weighs keywords by popularity

        vm.SelectedRows = [vm.Rows[1]];
        Assert.True(vm.RefreshPopularitySelectedCommand.CanExecute(null));
        await vm.RefreshPopularitySelectedCommand.ExecuteAsync(null);
        Assert.Equal(["--keywords", "slides maker"], cli.Calls[^2].TakeLast(2));
        vm.AdsConnected = false;
        Assert.False(vm.RefreshPopularitySelectedCommand.CanExecute(null));
    }

    [Fact]
    public async Task TheWindowFollowsTheAppleAdsConnection()
    {
        var adsStored = false;
        var cli = new FakeCli();
        cli.Respond = args => args.Contains("--version") ? FakeCli.Fixture("version") : FakeCli.Command(args) switch
        {
            "settings" => FakeCli.Fixture("settings"),
            "connections" => adsStored
                ? FakeCli.Ok("""[{"service":"apple-ads","title":"Apple Ads","configured":true,"details":{"keyID":"KEY"}}]""")
                : FakeCli.Fixture("connections"),
            "storefronts" => FakeCli.Fixture("storefronts"),
            "genres" => FakeCli.Fixture("genres"),
            _ => FakeCli.Ok("[]"),
        };
        var vm = new MainViewModel(new AsoClient(cli));
        await vm.LoadCommand.ExecuteAsync(null);
        Assert.False(vm.Keywords.AdsConnected);
        adsStored = true;
        await vm.Settings.Refresh();
        Assert.True(vm.Keywords.AdsConnected);
    }

    [Fact]
    public void RowsSortScoresAboveBoundsAboveUnread()
    {
        KeywordRow Row(int? popularity, string? source, int? below) =>
            new(new KeywordReportRow("k", "US", "iphone", "found", 1, 200, "#1", null, "", null, popularity, null, false, false, null, null,
                                     PopularitySource: source, PopularityBelow: below));
        var order = new[] { Row(null, null, null), Row(null, "belowRange", 31), Row(30, "list", null), Row(null, "belowRange", null) }
            .OrderByDescending(r => r.PopularityOrder).Select(r => r.Popularity);
        Assert.Equal(["30", "< 31", "< list", ""], order);
    }

    [Fact]
    public void MeasurementsAndRefreshesAreDescribed()
    {
        var september = new DateTimeOffset(2026, 9, 1, 0, 0, 0, TimeSpan.Zero);
        var refresh = new PopularityRefresh("DE", null, september, september.AddDays(29), 3, 3, 0, null, ["Business"]);
        Assert.Equal("Measured 3: 3 ranked, 0 outside the results, 0 failed. DE: 3 of 3 keyword(s) on Apple's list (September 2026).",
                     KeywordsViewModel.Describe(new MeasureSummary(3, 3, 0, 0, [refresh])));
        Assert.Equal("Measured 1: 0 ranked, 1 outside the results, 0 failed. Popularity was not refreshed: offline",
                     KeywordsViewModel.Describe(new MeasureSummary(1, 0, 1, 0, PopularityError: "offline")));
        // Months are UTC: the first of September stays September west of Greenwich.
        Assert.Equal("September 2026", KeywordsViewModel.Month(september.ToOffset(TimeSpan.FromHours(-7))));
    }

    [Fact]
    public async Task TheInspectorSaysWhereTheNumberComesFrom()
    {
        var rows = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("keywords-popularity") })
            .ListKeywordsAsync(1, ct: TestContext.Current.CancellationToken);
        Assert.StartsWith("61 of 100 · September 2026 · opportunity ", InspectorViewModel.Popularity(rows[0]), StringComparison.Ordinal);
        Assert.Equal("< 31: not on Apple's list · September 2026", InspectorViewModel.Popularity(rows[1]));
        var unread = (await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("keywords-list") })
            .ListKeywordsAsync(1, ct: TestContext.Current.CancellationToken))[0];
        Assert.StartsWith("Not read yet", InspectorViewModel.Popularity(unread), StringComparison.Ordinal);
    }
}
