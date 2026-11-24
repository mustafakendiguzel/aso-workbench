using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class CatalogContractTests
{
    private static AsoClient Client(string fixture) => new(new FakeCli { Respond = _ => FakeCli.Fixture(fixture) });

    [Fact]
    public async Task RatingsAreRead()
    {
        var rows = await Client("ratings-list").RatingsAsync(1, TestContext.Current.CancellationToken);
        Assert.Equal(["US", "GB"], rows.Select(r => r.Country));
        Assert.Equal("United States (US)", rows[0].Title);
        Assert.Equal(83879, rows[0].Count);
        Assert.Equal(12, rows[0].Delta);
        Assert.NotNull(rows[0].LastNewAt);
        Assert.Null(rows[1].Delta);   // first reading: absent, not zero
        Assert.Null(rows[1].PreviousAt);

        var check = await Client("ratings-check").CheckRatingsAsync(1, ct: TestContext.Current.CancellationToken);
        Assert.Equal(new RatingsCheck(2, 1, 0, [], []), check with { Failed = [], Unavailable = [] });
        Assert.Empty(check.Failed);
    }

    [Fact]
    public async Task ReviewsAreRead()
    {
        var report = await Client("reviews-list").ReviewsAsync(1, TestContext.Current.CancellationToken);
        Assert.Equal(3, report.Stored);
        Assert.Equal(1, report.New);
        Assert.Equal([0, 2, 0, 0, 1], report.Stars);
        Assert.Equal(["GB", "US"], report.Countries);
        Assert.True(report.Reviews[0].IsNew);
        Assert.Equal("US|14695812130", report.Reviews[0].Id);
        Assert.Null(report.Reviews[1].Version);
        Assert.Null(report.Reviews[2].Date);

        var check = await Client("reviews-check").CheckReviewsAsync(1, ct: TestContext.Current.CancellationToken);
        Assert.Equal(50, check.Stored);
        Assert.Equal(2, check.Storefronts);
    }

    [Fact]
    public async Task CompetitorsAreRead()
    {
        var report = await Client("competitors").CompetitorsAsync(1, "US", "iphone", 10, TestContext.Current.CancellationToken);
        Assert.Equal("US · iphone", report.Market);
        Assert.Equal(10, report.Depth);
        Assert.Equal(2, report.KeywordsMeasured);
        Assert.Equal(3, report.Competitors.Count);
        var first = report.Competitors[0];
        Assert.Equal(879478102, first.TrackId);
        Assert.Equal("com.google.Slides", first.BundleId);
        Assert.Equal(1.5, first.AveragePosition);
        Assert.Equal([("slides maker", 1), ("presentation", 2)], first.Appearances.Select(a => (a.Keyword, a.Position)));
        Assert.NotNull(first.CurrentVersionReleaseDate);
    }

    [Fact]
    public async Task ChecksAndListsBuildTheirArguments()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Ok("""{"storefronts":1,"recorded":0,"newRatings":0,"added":0,"stored":0,"failed":[],"unavailable":[]}""") };
        var client = new AsoClient(cli);
        var ct = TestContext.Current.CancellationToken;
        await client.CheckRatingsAsync(7, everyStorefront: true, ct);
        await client.CheckRatingsAsync(7, ct: ct);
        await client.CheckReviewsAsync(7, everyStorefront: true, ct);
        cli.Respond = _ => FakeCli.Fixture("competitors");
        await client.CompetitorsAsync(7, "DE", "ipad", 50, ct);
        Assert.Equal(["--json", "ratings", "check", "7", "--all"], cli.Calls[0]);
        Assert.Equal(["--json", "ratings", "check", "7"], cli.Calls[1]);
        Assert.Equal(["--json", "reviews", "check", "7", "--all"], cli.Calls[2]);
        Assert.Equal(["--json", "competitors", "7", "--country", "DE", "--device", "ipad", "--depth", "50"], cli.Calls[3]);
    }
}

public sealed class RelativeTimeTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 24, 12, 0, 0, TimeSpan.Zero);

    [Theory]
    [InlineData(0.2, "just now")]
    [InlineData(1, "1 minute ago")]
    [InlineData(45, "45 minutes ago")]
    [InlineData(60, "1 hour ago")]
    [InlineData(5 * 60, "5 hours ago")]
    [InlineData(30 * 60, "yesterday")]
    [InlineData(3 * 24 * 60, "3 days ago")]
    public void RecentMomentsReadAsDistances(double minutesAgo, string expected) =>
        Assert.Equal(expected, RelativeTime.Format(Now.AddMinutes(-minutesAgo), Now));

    [Fact]
    public void OlderMomentsAreDates() =>
        Assert.DoesNotContain("ago", RelativeTime.Format(Now.AddDays(-90), Now), StringComparison.Ordinal);
}

public sealed class RatingsViewModelTests
{
    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);
    private static readonly DateTimeOffset Now = new(2026, 10, 24, 7, 42, 20, TimeSpan.Zero);   // the fixture's US check

    private static (RatingsViewModel, FakeCli, StatusViewModel) Make()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Command(args) switch
        {
            "ratings list" => FakeCli.Fixture("ratings-list"),
            "reviews list" => FakeCli.Fixture("reviews-list"),
            "ratings check" => FakeCli.Ok("""{"storefronts":2,"recorded":2,"newRatings":5,"failed":["JP"],"unavailable":[]}"""),
            _ => FakeCli.Ok("{}"),
        };
        var status = new StatusViewModel();
        return (new RatingsViewModel(new AsoClient(cli), status, () => Now), cli, status);
    }

    [Fact]
    public void SelectingAnAppLoadsItsRatingsAndLatestReview()
    {
        var (vm, _, status) = Make();
        Assert.False(vm.CheckCommand.CanExecute("markets"));
        vm.App = App;

        Assert.True(vm.HasRows);
        Assert.Equal("Last new rating: United States · just now", vm.Headline);
        var us = vm.Rows[0];
        Assert.Equal("+12", us.SinceLastCheck);
        Assert.Equal("just now", us.LastNewRating);
        Assert.Equal("first check", vm.Rows[1].SinceLastCheck);
        Assert.Equal("—", vm.Rows[1].LastNewRating);
        Assert.StartsWith("Latest written review: US · 2★ “Voice-over is broken”", vm.LatestReview, StringComparison.Ordinal);
        Assert.EndsWith("3 stored, see Reviews.", vm.LatestReview, StringComparison.Ordinal);
        Assert.False(status.IsError);
        Assert.True(vm.CheckCommand.CanExecute("markets"));
    }

    [Fact]
    public async Task CheckingReadsTheMarketsOrEveryStorefrontAndReportsFailures()
    {
        var (vm, cli, status) = Make();
        vm.App = App;
        await vm.CheckCommand.ExecuteAsync("markets");
        await vm.CheckCommand.ExecuteAsync("all");
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "ratings", "check", "361285480"]));
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "ratings", "check", "361285480", "--all"]));
        Assert.Equal("Checked 2 storefront(s): 5 new rating(s) since the previous check. Failed: JP.", status.Message);
    }

    [Fact]
    public void TheHeadlineSaysWhatIsKnown()
    {
        Assert.StartsWith("No ratings recorded yet.", RatingsViewModel.HeadlineFor([], Now), StringComparison.Ordinal);
        RatingRow quiet = new("US", "United States", 1200, 4.5, 0, Now.AddDays(-1), Now, null);
        Assert.StartsWith("No new rating seen between checks yet (1 storefront(s), ", RatingsViewModel.HeadlineFor([quiet], Now), StringComparison.Ordinal);
        RatingRow older = quiet with { Country = "DE", CountryName = "Germany", LastNewAt = Now.AddDays(-3) };
        RatingRow newer = quiet with { Country = "FR", CountryName = "France", LastNewAt = Now.AddHours(-2) };
        Assert.Equal("Last new rating: France · 2 hours ago", RatingsViewModel.HeadlineFor([older, newer, quiet], Now));
    }
}

public sealed class ReviewsViewModelTests
{
    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);

    private static (ReviewsViewModel, FakeCli, StatusViewModel) Make()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Command(args) switch
        {
            "reviews list" => FakeCli.Fixture("reviews-list"),
            "reviews check" => FakeCli.Fixture("reviews-check"),
            _ => FakeCli.Ok("{}"),
        };
        var status = new StatusViewModel();
        return (new ReviewsViewModel(new AsoClient(cli), status) { App = App }, cli, status);
    }

    [Fact]
    public void TheReportFillsTheListTotalsAndStorefronts()
    {
        var (vm, _, _) = Make();
        Assert.False(vm.IsEmpty);
        Assert.Equal(3, vm.Visible.Count);
        Assert.Equal("3 stored · 1 new", vm.Summary);
        Assert.StartsWith("5★ 1  4★ 0  3★ 0  2★ 2  1★ 0  avg ", vm.StarCounts, StringComparison.Ordinal);
        Assert.Equal([ReviewsViewModel.AllStorefronts, "GB", "US"], vm.Countries);

        var first = vm.Visible[0];
        Assert.Equal("★★☆☆☆", first.Stars);
        Assert.True(first.IsBad);
        Assert.False(first.IsGood);
        Assert.StartsWith("Reviewer A · v15.4 · US · ", first.Byline, StringComparison.Ordinal);
        Assert.StartsWith("Reviewer B · GB · ", vm.Visible[1].Byline, StringComparison.Ordinal);   // no version: left out
        Assert.True(vm.Visible[1].IsGood);
    }

    [Fact]
    public void FiltersNarrowTheListAndResetRestoresIt()
    {
        var (vm, _, _) = Make();
        vm.Country = "GB";
        Assert.Equal(["Lovely templates"], vm.Visible.Select(r => r.Review.Title));
        vm.Country = ReviewsViewModel.AllStorefronts;
        vm.MinRating = 3;
        Assert.Equal(["Lovely templates"], vm.Visible.Select(r => r.Review.Title));
        vm.MinRating = 1;
        vm.OnlyNew = true;
        Assert.Equal(["Voice-over is broken"], vm.Visible.Select(r => r.Review.Title));
        vm.OnlyNew = false;
        vm.Search = "SIMPLE";   // the body, ignoring case under any culture
        Assert.Equal(["Does the job"], vm.Visible.Select(r => r.Review.Title));

        vm.ClearFiltersCommand.Execute(null);
        Assert.Equal(3, vm.Visible.Count);
    }

    [Fact]
    public async Task CheckingReadsAndReloads()
    {
        var (vm, cli, status) = Make();
        vm.Country = "US";
        await vm.CheckCommand.ExecuteAsync("all");
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "reviews", "check", "361285480", "--all"]));
        Assert.Equal("Checked 2 storefront(s): 0 new review(s), 50 stored.", status.Message);
        Assert.Equal("US", vm.Country);   // a storefront that still has reviews stays chosen

        vm.App = null;
        Assert.True(vm.IsEmpty);
        Assert.Empty(vm.Visible);
        Assert.Equal([ReviewsViewModel.AllStorefronts], vm.Countries);
    }
}

public sealed class CompetitorsViewModelTests
{
    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);
    private static readonly MarketSummary Us = new("US", "United States", "iphone", 2, null);

    [Fact]
    public async Task TheMarketAndDepthLoadTheListAndTheSelectionSurvivesReloads()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("competitors") };
        var vm = new CompetitorsViewModel(new AsoClient(cli), new StatusViewModel()) { App = App };
        Assert.False(vm.RefreshCommand.CanExecute(null));
        vm.Market = Us;

        Assert.True(vm.HasMeasurements);
        Assert.Equal("Apps seen in the top 10 of your 2 measured keyword(s) in US · iphone", vm.Headline);
        Assert.Equal(3, vm.Rows.Count);
        var google = vm.Rows[0];
        Assert.Equal("1.5", google.AveragePosition.Replace(',', '.'));
        Assert.Equal("App ID 879478102 · com.google.Slides", google.Identifiers);
        Assert.Equal("Google LLC · Productivity", google.Details);

        vm.Selected = vm.Rows[1];
        vm.Depth = 20;
        Assert.Equal(["--json", "competitors", "361285480", "--country", "US", "--device", "iphone", "--depth", "20"], cli.Calls[^1]);
        Assert.Equal(586449534, vm.Selected?.App.TrackId);

        await vm.RefreshCommand.ExecuteAsync(null);
        Assert.Equal(3, cli.Calls.Count);

        vm.Market = null;
        Assert.Empty(vm.Rows);
        Assert.Null(vm.Selected);
    }

    [Fact]
    public void WithoutMeasurementsItSaysToMeasureFirst()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Ok("""{"market":"US · iphone","depth":10,"keywordsMeasured":0,"competitors":[]}""") };
        var vm = new CompetitorsViewModel(new AsoClient(cli), new StatusViewModel()) { App = App, Market = Us };
        Assert.False(vm.HasMeasurements);
        Assert.StartsWith("No measurements yet.", vm.Headline, StringComparison.Ordinal);
    }
}
