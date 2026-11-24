using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class MainViewModelTests
{
    private static (MainViewModel, FakeCli) Make(Func<string, CliResult> byCommand)
    {
        var cli = new FakeCli();
        cli.Respond = args => args.Contains("--version") ? FakeCli.Fixture("version") : byCommand(FakeCli.Command(args));
        return (new MainViewModel(new AsoClient(cli)), cli);
    }

    [Fact]
    public async Task LoadingShowsAppsSelectsTheFirstAndLoadsItsKeywords()
    {
        var (vm, cli) = Make(command => command switch
        {
            "app list" => FakeCli.Fixture("app-list"),
            "keywords list" => FakeCli.Fixture("keywords-list"),
            _ => throw new InvalidOperationException(command),
        });
        await vm.LoadCommand.ExecuteAsync(null);
        await vm.Keywords.RefreshCommand.ExecuteAsync(null);

        Assert.Equal("1.0.0", vm.EngineVersion);
        Assert.Equal(361285480, Assert.Single(vm.Apps).TrackId);
        Assert.Same(vm.Apps[0], vm.SelectedApp);
        Assert.Same(vm.SelectedApp, vm.Keywords.App);
        Assert.Equal(2, vm.Keywords.Rows.Count);
        Assert.False(vm.Status.IsError);
        Assert.Contains(cli.Calls, c => FakeCli.Command(c) == "keywords list");
    }

    [Fact]
    public async Task AddingAnAppClearsTheFieldAndSelectsIt()
    {
        var (vm, cli) = Make(command => command switch
        {
            "app add" => FakeCli.Fixture("app-add"),
            "app list" => FakeCli.Fixture("app-list"),
            _ => FakeCli.Ok("[]"),
        });
        Assert.False(vm.AddAppCommand.CanExecute(null));
        vm.NewAppReference = " https://apps.apple.com/us/app/keynote/id361285480 ";
        Assert.True(vm.AddAppCommand.CanExecute(null));

        await vm.AddAppCommand.ExecuteAsync(null);

        Assert.Equal(["--json", "app", "add", "https://apps.apple.com/us/app/keynote/id361285480", "--country", "US"],
                     cli.Calls.First(c => FakeCli.Command(c) == "app add"));
        Assert.Equal("", vm.NewAppReference);
        Assert.Equal(361285480, vm.SelectedApp?.TrackId);
        Assert.Equal("Tracking Keynote: Design Presentations.", vm.Status.Message);
    }

    [Fact]
    public async Task EngineErrorsLandInTheStatusLine()
    {
        var (vm, _) = Make(_ => new CliResult(1, "", "error: No app with ID 1234567 in the United States App Store.\n"));
        vm.NewAppReference = "1234567";
        await vm.AddAppCommand.ExecuteAsync(null);
        Assert.True(vm.Status.IsError);
        Assert.Equal("No app with ID 1234567 in the United States App Store.", vm.Status.Message);
        Assert.False(vm.Status.IsBusy);
        Assert.Equal("1234567", vm.NewAppReference);   // kept, so it can be corrected
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
            _ => FakeCli.Ok("[]"),
        });
        await vm.LoadCommand.ExecuteAsync(null);
        await vm.RemoveAppCommand.ExecuteAsync(vm.SelectedApp);
        Assert.Empty(vm.Apps);
        Assert.Null(vm.SelectedApp);
        Assert.Null(vm.Keywords.App);
    }
}

public sealed class KeywordsViewModelTests
{
    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);

    private static (KeywordsViewModel, FakeCli, StatusViewModel) Make(Func<string, CliResult> byCommand)
    {
        var cli = new FakeCli();
        cli.Respond = args => byCommand(FakeCli.Command(args));
        var status = new StatusViewModel();
        return (new KeywordsViewModel(new AsoClient(cli), status) { App = App }, cli, status);
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
    public async Task AddingKeywordsSendsTheMarketAndReloads()
    {
        var (vm, cli, status) = Make(command => command == "keywords add" ? FakeCli.Fixture("keywords-add") : FakeCli.Fixture("keywords-list"));
        vm.NewKeywords = "presentation\nslides maker";
        vm.NewCountry = "us";
        await vm.AddKeywordsCommand.ExecuteAsync(null);

        Assert.Equal(["--json", "keywords", "add", "361285480", "--country", "us", "--device", "iphone", "--", "presentation", "slides maker"],
                     cli.Calls[0]);
        Assert.Equal("", vm.NewKeywords);
        Assert.Equal(2, vm.Rows.Count);
        Assert.Equal("Added 2 keyword(s) in US · iphone.", status.Message);
    }

    [Fact]
    public async Task MeasuringReportsTheSummaryAndClearsProgress()
    {
        var (vm, cli, status) = Make(command => command == "measure" ? FakeCli.Fixture("measure") : FakeCli.Fixture("keywords-list"));
        await vm.MeasureCommand.ExecuteAsync(null);
        Assert.Equal("Measured 2: 1 ranked, 1 outside the results, 0 failed.", status.Message);
        Assert.Null(vm.MeasureStepText);
        Assert.Equal(["--json", "measure", "361285480"], cli.Calls[0]);
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
    public async Task ChangingTheAppClearsTheOldRows()
    {
        var (vm, _, _) = Make(_ => FakeCli.Fixture("keywords-list"));
        await vm.RefreshCommand.ExecuteAsync(null);
        vm.App = null;
        Assert.Empty(vm.Rows);
        Assert.False(vm.MeasureCommand.CanExecute(null));
    }
}

public sealed class ResearchAndMetadataViewModelTests
{
    [Fact]
    public async Task SearchHintsAndDifficultyFillTheirPanels()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Fixture(FakeCli.Command(args) switch { "search" => "search", "hints" => "hints", _ => "difficulty" });
        var status = new StatusViewModel();
        var vm = new ResearchViewModel(new AsoClient(cli), status);
        Assert.False(vm.SearchCommand.CanExecute(null));

        vm.Term = " keynote ";
        await vm.SearchCommand.ExecuteAsync(null);
        await vm.HintsCommand.ExecuteAsync(null);
        await vm.DifficultyCommand.ExecuteAsync(null);

        Assert.Single(vm.Results);
        Assert.Equal(10, vm.Hints.Count);
        Assert.Equal(57, vm.Difficulty?.Score);
        Assert.Equal(["--json", "search", "--country", "US", "--device", "iphone", "--limit", "25", "--", "keynote"], cli.Calls[0]);

        vm.UseHintCommand.Execute("presentation");
        Assert.Equal("presentation", vm.Term);
    }

    [Fact]
    public void LengthsCountCodePointsLikeTheAppStore()
    {
        Assert.Equal(5, MetadataViewModel.CodePoints("Notes"));
        Assert.Equal(4, MetadataViewModel.CodePoints("Bütç"));
        Assert.Equal(2, MetadataViewModel.CodePoints("😀😀"));   // four UTF-16 units, two characters
    }

    [Fact]
    public async Task ErrorsFromTheCheckAreShownFirstAndFlagTheStatus()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("validate") with { ExitCode = 1 } };
        var status = new StatusViewModel();
        var vm = new MetadataViewModel(new AsoClient(cli), status) { Title = new string('A', 31) };
        Assert.Equal(31, vm.TitleLength);

        await vm.CheckCommand.ExecuteAsync(null);

        Assert.Equal(ValidationSeverity.Error, vm.Issues[0].Severity);
        Assert.True(status.IsError);
        Assert.StartsWith("1 error(s)", status.Message, StringComparison.Ordinal);
    }
}
