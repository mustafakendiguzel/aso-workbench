using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class KeywordDetailContractTests
{
    [Fact]
    public async Task DetailIsRead()
    {
        var detail = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("keyword-show") })
            .KeywordDetailAsync(361285480, "presentation", "US", "iphone", "previous", TestContext.Current.CancellationToken);
        Assert.Equal("presentation", detail.Row.Keyword);
        Assert.Equal("Keep in the subtitle", detail.Row.Note);
        Assert.Equal(new KeywordDetailSummary(3, 3, 1, 0), detail.Summary);
        Assert.Equal("found", Assert.Single(detail.Observations).Status);
        Assert.Equal(10, detail.TopResults.Count);
        Assert.Contains(detail.TopResults, r => r.IsOwnApp && r.TrackId == 361285480);   // other apps from the same seller are marked too
        Assert.Equal(3, detail.TopResults.First(r => r.TrackId == 361285480).Position);
        Assert.Equal(7, detail.Difficulty?.Components.Count);
        Assert.Equal("Hard", detail.Row.DifficultyTier);
        Assert.NotNull(detail.Row.RatingMass);
    }

    [Fact]
    public async Task CsvIsTheEngineTextAndTheArgumentsAreRight()
    {
        var csv = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "keywords.csv"));
        var cli = new FakeCli { Respond = _ => FakeCli.Ok(csv) };
        var text = await new AsoClient(cli).KeywordsCsvAsync(1, "US", "iphone", "week", TestContext.Current.CancellationToken);
        Assert.Equal(csv, text);
        Assert.StartsWith("keyword,storefront,device,rank", text, StringComparison.Ordinal);
        Assert.Equal(["keywords", "list", "1", "--country", "US", "--device", "iphone", "--delta", "week", "--csv"], cli.Calls[0]);
    }

    [Fact]
    public async Task NotesAndSelectedMeasuringBuildTheirArguments()
    {
        var cli = new FakeCli { Respond = args => args.Contains("measure") ? FakeCli.Fixture("measure") : FakeCli.Ok("{}") };
        var client = new AsoClient(cli);
        await client.SetNoteAsync(1, "-dash", "US", "iphone", "", TestContext.Current.CancellationToken);
        await client.MeasureKeywordsAsync(1, "US", "iphone", ["a b", "c"], ct: TestContext.Current.CancellationToken);
        Assert.Equal(["--json", "keywords", "note", "1", "--country", "US", "--device", "iphone", "--text", "", "--", "-dash"], cli.Calls[0]);
        Assert.Equal(["--json", "measure", "1", "--country", "US", "--device", "iphone", "--keywords", "a b,c"], cli.Calls[1]);
    }
}

public sealed class InspectorViewModelTests
{
    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);
    private static readonly MarketSummary Us = new("US", "United States", "iphone", 2, null);

    private static KeywordObservation Obs(int daysAgo, int? rank, string status = "found") =>
        new(new DateTimeOffset(2026, 10, 24, 0, 0, 0, TimeSpan.Zero).AddDays(-daysAgo), status, rank, 200, rank is { } r ? $"#{r}" : "> 200", "itunes-search", null);

    private static KeywordDetail Detail(params KeywordObservation[] observations)
    {
        var row = new KeywordReportRow("notes", "US", "iphone", "found", 3, 200, "#3", null, "previous measurement", 40, null, null, false, false, null, null);
        return new KeywordDetail(row, new KeywordDetailSummary(3, 3, observations.Length, 0), observations, [], null);
    }

    [Fact]
    public void ChartPointsFollowTheRangeAndSkipFailures()
    {
        var detail = Detail(Obs(100, 50), Obs(40, 20), Obs(20, null, "outside"), Obs(5, 8), Obs(1, null, "failed"), Obs(0, 3));
        Assert.Equal(5, InspectorViewModel.Points(detail, "All").Count);
        Assert.Equal([null, 8, 3], InspectorViewModel.Points(detail, "30D").Select(p => p.Rank));   // 40 days ago is outside the range
        Assert.Equal([8, 3], InspectorViewModel.Points(detail, "7D").Select(p => p.Rank));
        Assert.Empty(InspectorViewModel.Points(null, "All"));
        Assert.Empty(InspectorViewModel.Points(Detail(Obs(0, null, "failed")), "All"));
    }

    [Fact]
    public async Task ShowingLoadsTheDetailAndSavingTheNoteSendsItTrimmed()
    {
        var cli = new FakeCli { Respond = args => FakeCli.Command(args) == "keywords show" ? FakeCli.Fixture("keyword-show") : FakeCli.Ok("{}") };
        var status = new StatusViewModel();
        var vm = new InspectorViewModel(new AsoClient(cli), status);
        var row = new KeywordRow(Detail().Row with { Keyword = "presentation" });

        await vm.ShowAsync(App, Us, row, "week");
        Assert.True(vm.HasDetail);
        Assert.Equal("Keep in the subtitle", vm.NoteText);
        Assert.Equal("Latest #3 · best #3 · 1 measurement(s), 0 outside the results", vm.SummaryText);
        Assert.Equal(["--json", "keywords", "show", "361285480", "--country", "US", "--device", "iphone", "--delta", "week", "--", "presentation"], cli.Calls[0]);
        Assert.False(vm.SaveNoteCommand.CanExecute(null));

        vm.NoteText = "  Try it in the title  ";
        Assert.True(vm.SaveNoteCommand.CanExecute(null));
        await vm.SaveNoteCommand.ExecuteAsync(null);
        Assert.Equal("Try it in the title", cli.Calls[1][cli.Calls[1].ToList().IndexOf("--text") + 1]);
        Assert.Equal("Try it in the title", vm.Detail?.Row.Note);
        Assert.False(vm.SaveNoteCommand.CanExecute(null));

        await vm.ShowAsync(App, Us, null, "week");
        Assert.False(vm.HasDetail);
        Assert.Equal("", vm.NoteText);
    }
}

public sealed class KeywordFilterAndSelectionTests
{
    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);
    private static readonly MarketSummary Us = new("US", "United States", "iphone", 2, null);

    private static async Task<(KeywordsViewModel, FakeCli, StatusViewModel)> LoadedAsync()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Command(args) switch
        {
            "keywords list" => FakeCli.Fixture("keywords-list"),
            "keywords show" => FakeCli.Fixture("keyword-show"),
            "measure" => FakeCli.Fixture("measure"),
            "keywords remove" => FakeCli.Ok("""{"removed":1}"""),
            _ => FakeCli.Ok("{}"),
        };
        var status = new StatusViewModel();
        var vm = new KeywordsViewModel(new AsoClient(cli), status) { App = App, Market = Us };
        await vm.RefreshCommand.ExecuteAsync(null);
        return (vm, cli, status);
    }

    [Fact]
    public async Task FiltersNarrowTheTableAndResetRestoresIt()
    {
        var (vm, _, _) = await LoadedAsync();
        Assert.Equal(2, vm.VisibleRows.Count);
        Assert.Equal("2 keyword(s)", vm.FilterSummary);

        vm.FoundOnly = true;
        Assert.Equal(["presentation"], vm.VisibleRows.Select(r => r.Keyword));
        vm.FoundOnly = false;
        vm.HideBrands = true;
        Assert.Equal(["presentation"], vm.VisibleRows.Select(r => r.Keyword));
        vm.HideBrands = false;
        vm.MaxDifficulty = 57;
        Assert.Equal(["presentation"], vm.VisibleRows.Select(r => r.Keyword));   // 57.7 is over 57
        vm.MaxDifficulty = 100;
        vm.FilterText = "SLIDES";
        Assert.Equal(["slides maker"], vm.VisibleRows.Select(r => r.Keyword));
        Assert.Equal("1 of 2 keyword(s)", vm.FilterSummary);

        vm.ClearFiltersCommand.Execute(null);
        Assert.Equal(2, vm.VisibleRows.Count);
    }

    [Fact]
    public async Task SelectedKeywordsCanBeMeasuredCopiedAndRemoved()
    {
        var (vm, cli, status) = await LoadedAsync();
        Assert.False(vm.MeasureSelectedCommand.CanExecute(null));
        vm.SelectedRows = vm.VisibleRows.ToList();
        Assert.Equal("2 selected", vm.SelectionText);
        Assert.Equal($"presentation{Environment.NewLine}slides maker", vm.SelectedKeywordsText);

        await vm.MeasureSelectedCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "measure", "361285480", "--country", "US", "--device", "iphone", "--keywords", "presentation,slides maker"]));

        vm.SelectedRows = [vm.VisibleRows[1]];
        await vm.RemoveSelectedCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "keywords", "remove", "361285480", "--country", "US", "--device", "iphone", "--", "slides maker"]));
        Assert.Empty(vm.SelectedRows);
        Assert.Equal("Removed 1 keyword(s) from US · iphone.", status.Message);
    }

    [Fact]
    public async Task SelectingARowFillsTheInspectorAndReloadsKeepIt()
    {
        var (vm, _, _) = await LoadedAsync();
        vm.SelectedRow = vm.VisibleRows[0];
        Assert.True(vm.Inspector.HasDetail);
        await vm.RefreshCommand.ExecuteAsync(null);
        Assert.Equal("presentation", vm.SelectedRow?.Keyword);
        vm.Market = new MarketSummary("DE", "Germany", "iphone", 0, null);
        Assert.Null(vm.SelectedRow);
        Assert.False(vm.Inspector.HasDetail);
    }

    [Fact]
    public async Task ExportReturnsTheCsvAndNamesTheFile()
    {
        var csv = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "keywords.csv"));
        var cli = new FakeCli { Respond = args => args.Contains("--csv") ? FakeCli.Ok(csv) : FakeCli.Fixture("keywords-list") };
        var vm = new KeywordsViewModel(new AsoClient(cli), new StatusViewModel())
        {
            App = App with { Name = "Keynote: Design Presentations" },
            Market = Us,
        };
        Assert.Equal(csv, await vm.ExportCsvAsync());
        Assert.Equal("keynote-US-iphone-keywords.csv", vm.ExportFileName);
    }
}
