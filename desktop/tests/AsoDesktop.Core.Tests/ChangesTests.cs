using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class ChangesContractTests
{
    private static AsoClient Client(string fixture) => new(new FakeCli { Respond = _ => FakeCli.Fixture(fixture) });

    [Fact]
    public async Task MarkersAreRead()
    {
        var markers = await Client("markers-list").MarkersAsync(1, TestContext.Current.CancellationToken);
        Assert.Equal(["Keywords updated", "v15.4.2"], markers.Select(m => m.Title));
        Assert.False(markers[0].IsRelease);
        Assert.Null(markers[0].Version);
        Assert.Null(markers[0].Country);
        var release = markers[1];
        Assert.True(release.IsRelease);
        Assert.Equal("15.4.2", release.Version);
        Assert.Equal("US", release.Country);
        Assert.Equal(new DateTimeOffset(2026, 10, 23, 3, 50, 39, TimeSpan.Zero), release.Date);
    }

    [Fact]
    public async Task ImpactIsRead()
    {
        var report = await Client("impact").ImpactAsync(1, 2, TestContext.Current.CancellationToken);
        Assert.Equal(2, report.Marker.Id);
        Assert.Equal((0, 0, 2), (report.Improved, report.Worsened, report.Same));
        Assert.Equal(0, report.Net);
        var presentation = report.Rows[0];
        Assert.Equal(("presentation", 3, 3, 39), (presentation.Keyword, presentation.Before, presentation.After, presentation.Depth));
        Assert.Equal(57, presentation.Difficulty);
        Assert.Null(presentation.Popularity);   // absent until Apple Ads popularity arrives, never 0
        Assert.Null(presentation.Fit);
        Assert.Equal("None", presentation.Tier);
        Assert.Null(report.Rows[1].Before);    // outside the results
        Assert.Equal(47, report.Rows[1].Depth);
    }

    [Fact]
    public async Task ReleasesFoundByARatingsCheckAreRead()
    {
        var client = new AsoClient(new FakeCli
        {
            Respond = _ => FakeCli.Ok("""
                {"storefronts":1,"recorded":1,"newRatings":0,"failed":[],"unavailable":[],
                 "newRelease":{"id":3,"date":"2026-10-23T03:50:39Z","kind":"release","title":"v15.4.2","version":"15.4.2","country":"US"}}
                """),
        });
        var check = await client.CheckRatingsAsync(1, ct: TestContext.Current.CancellationToken);
        Assert.Equal("v15.4.2", check.NewRelease?.Title);
    }

    [Fact]
    public async Task CallsBuildTheirArguments()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Ok("""{"id":5,"date":"2026-10-20T12:30:00Z","kind":"note","title":"New screenshots"}""") };
        var client = new AsoClient(cli);
        var ct = TestContext.Current.CancellationToken;
        await client.AddNoteAsync(7, "New screenshots", new DateTimeOffset(2026, 10, 20, 14, 30, 0, TimeSpan.FromHours(2)), ct);
        await client.RemoveMarkerAsync(7, 5, ct);
        cli.Respond = _ => FakeCli.Fixture("impact");
        await client.ImpactAsync(7, 5, ct);
        cli.Respond = _ => FakeCli.Fixture("markers-list");
        await client.MarkersAsync(7, ct);
        Assert.Equal(["--json", "markers", "add", "7", "--title", "New screenshots", "--date", "2026-10-20T12:30:00Z"], cli.Calls[0]);
        Assert.Equal(["--json", "markers", "remove", "7", "5"], cli.Calls[1]);
        Assert.Equal(["--json", "impact", "7", "5"], cli.Calls[2]);
        Assert.Equal(["--json", "markers", "list", "7"], cli.Calls[3]);
    }
}

public sealed class ChangesViewModelTests
{
    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);
    private static readonly DateTimeOffset At = new(2026, 10, 24, 9, 0, 0, TimeSpan.Zero);
    private static readonly Marker Release = new(1, At, "release", "v2.0", "2.0", "US");

    private static ImpactRow Row(string keyword, int? before, int? after, int delta, double value = 0, double gain = 0, string country = "US",
                                 string tier = "None") =>
        new(keyword, country, "iphone", before, At.AddHours(-1), after, At.AddHours(1), 200, delta, value > 0 ? 50 : null, 40, null, false, value, gain, tier);

    /// <summary>Two moves with value, one without, one unchanged, in two markets.</summary>
    private static readonly ImpactReport Report = new(Release, 2, 2, 1, 12.5, -4, 8.5,
    [
        Row("notes", 12, 3, 9, value: 25, gain: 13.75, tier: "Medium"),
        Row("journal", 4, 9, -5, value: 40, gain: -6, tier: "High"),
        Row("planner", 30, 2, 28),
        Row("diary", 8, 8, 0),
        Row("todo", null, 50, 151, country: "DE"),
    ]);

    private static (ChangesViewModel, FakeCli, StatusViewModel) Make()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Command(args) switch
        {
            "markers list" => FakeCli.Ok($"[{Json(Release)}]"),
            "impact" => FakeCli.Ok(System.Text.Json.JsonSerializer.Serialize(Report, Options)),
            "markers add" => FakeCli.Ok("""{"id":2,"date":"2026-10-24T08:00:00Z","kind":"note","title":"New screenshots"}"""),
            _ => FakeCli.Ok("{}"),
        };
        var status = new StatusViewModel();
        return (new ChangesViewModel(new AsoClient(cli), status, () => At), cli, status);
    }

    private static readonly System.Text.Json.JsonSerializerOptions Options = new() { PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase };
    private static string Json(Marker marker) => System.Text.Json.JsonSerializer.Serialize(marker, Options);

    [Fact]
    public void SelectingAnAppLoadsTheTimelineAndAMarkerItsImpact()
    {
        var (vm, cli, status) = Make();
        Assert.False(vm.AddNoteCommand.CanExecute(null));
        vm.App = App;
        var line = Assert.Single(vm.Markers);
        Assert.Equal("Release", line.Kind);
        Assert.Equal("seen in US", line.SeenIn);
        Assert.False(vm.HasSelection);
        Assert.Null(vm.Report);

        vm.Selected = line;
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "impact", "361285480", "1"]));
        Assert.StartsWith("Effect of v2.0 · ", vm.Headline, StringComparison.Ordinal);
        Assert.True(vm.HasRows);
        Assert.Equal("+8.5", vm.Net.Replace(',', '.'));
        Assert.True(vm.NetIsUp);
        Assert.Equal("2 · 2 · 1", vm.Counts);
        Assert.False(vm.NoValues);
        Assert.Equal(["All markets", "DE · iphone", "US · iphone"], vm.MarketFilters);
        Assert.False(status.IsError);
    }

    [Fact]
    public void ModesAndFiltersChooseAndOrderTheRows()
    {
        var (vm, _, _) = Make();
        vm.App = App;
        vm.Selected = vm.Markers[0];

        // Improved: biggest gain first, then the biggest move among keywords without value.
        Assert.Equal(["notes", "todo", "planner"], vm.Visible.Select(r => r.Keyword));
        Assert.Equal("3 of 5", vm.Shown);
        vm.Mode = "Worsened";
        Assert.Equal(["journal"], vm.Visible.Select(r => r.Keyword));
        vm.Mode = "All";
        Assert.Equal(5, vm.Visible.Count);
        vm.MarketFilter = "DE · iphone";
        Assert.Equal(["todo"], vm.Visible.Select(r => r.Keyword));
        vm.MarketFilter = ChangesViewModel.AllMarkets;
        vm.ValueFilter = "Medium and above";
        Assert.Equal(["notes", "journal"], vm.Visible.Select(r => r.Keyword));
        vm.ValueFilter = "High only";
        Assert.Equal(["journal"], vm.Visible.Select(r => r.Keyword));
        vm.ValueFilter = "Any value";
        vm.Search = "NOT";   // ordinal, case-insensitive
        Assert.Equal(["notes"], vm.Visible.Select(r => r.Keyword));
    }

    [Fact]
    public void LinesShowRanksMovesAndValue()
    {
        var notes = new ImpactLine(Report.Rows[0]);
        Assert.Equal(("#12", "#3", "+9"), (notes.Before, notes.After, notes.DeltaText));
        Assert.True(notes.IsUp && notes.Gained && notes.HasValue);
        Assert.Equal("13.75", notes.GainText.TrimStart('+').Replace(',', '.'));
        Assert.StartsWith("pop 50 · diff 40", notes.Components, StringComparison.Ordinal);

        var todo = new ImpactLine(Report.Rows[4]);
        Assert.Equal("> 200", todo.Before);
        Assert.Equal("0 · no value", todo.GainText);
        Assert.False(todo.Gained);
        Assert.Contains("popularity ?", todo.ValueHint, StringComparison.Ordinal);
        Assert.Equal("—", new ImpactLine(Report.Rows[3]).DeltaText);
    }

    [Fact]
    public async Task NotesAreAddedAndMarkersRemoved()
    {
        var (vm, cli, status) = Make();
        vm.App = App;
        vm.NoteTitle = "  New screenshots ";
        Assert.True(vm.AddNoteCommand.CanExecute(null));
        await vm.AddNoteCommand.ExecuteAsync(null);
        var add = Assert.Single(cli.Calls, c => FakeCli.Command(c) == "markers add");
        Assert.Equal(["--json", "markers", "add", "361285480", "--title", "New screenshots", "--date", "2026-10-24T09:00:00Z"], add);
        Assert.Equal("", vm.NoteTitle);
        Assert.Equal("Added the note “New screenshots”.", status.Message);

        vm.Selected = vm.Markers[0];
        Assert.True(vm.RemoveSelectedCommand.CanExecute(null));
        await vm.RemoveSelectedCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "markers", "remove", "361285480", "1"]));
        Assert.Equal("Removed the release “v2.0”.", status.Message);
    }

    [Fact]
    public void ANoteIsDatedTheChosenDayAndTimeElseNow()
    {
        var now = new DateTimeOffset(2026, 10, 24, 15, 45, 0, TimeZoneInfo.Local.GetUtcOffset(new DateTime(2026, 10, 24, 15, 45, 0)));
        Assert.Equal(now, ChangesViewModel.NoteMoment(null, null, now));
        var day = new DateTimeOffset(2026, 10, 20, 0, 0, 0, now.Offset);
        var onDay = ChangesViewModel.NoteMoment(day, null, now);
        Assert.Equal((20, 15, 45), (onDay.Day, onDay.Hour, onDay.Minute));
        var atTime = ChangesViewModel.NoteMoment(day, new TimeSpan(9, 30, 0), now);
        Assert.Equal((20, 9, 30), (atTime.Day, atTime.Hour, atTime.Minute));
        var todayAt = ChangesViewModel.NoteMoment(null, new TimeSpan(8, 0, 0), now);
        Assert.Equal((24, 8), (todayAt.Day, todayAt.Hour));
    }
}
