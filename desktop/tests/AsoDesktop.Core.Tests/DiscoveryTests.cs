using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class DiscoveryTests
{
    // discover.json is the real engine's answer without keys (seed "presentation", no difficulty searches). Scored.json
    // below has the shape of a run with Apple Ads and Jev, which the engine's own tests pin.
    private const string Scored = """
        {"market":"US · iphone","seeds":["notes"],"appleAds":true,"jev":true,"withPopularity":2,"measured":2,"golden":1,
         "candidates":[
           {"keyword":"notes app","sources":["autocomplete","ads suggestion"],"tracked":false,"golden":true,"goldenLead":false,
            "popularity":55,"popularitySource":"list","popularityGenre":"PRODUCTIVITY_UTILITIES","brand":0.05,"natural":0.9,
            "intent":"feature","fit":0.9,"difficulty":21.4,"difficultyTier":"Easy","opportunity":52.5},
           {"keyword":"notes widget","sources":["autocomplete"],"tracked":false,"golden":false,"goldenLead":true,
            "popularity":40,"popularitySource":"list","fit":0.1,"difficulty":21.4,"opportunity":38.2},
           {"keyword":"notion","sources":["autocomplete"],"tracked":false,"golden":false,"goldenLead":false,"brand":0.9,
            "popularitySource":"belowRange"},
           {"keyword":"notes","sources":["autocomplete"],"tracked":true,"golden":true,"goldenLead":false,"popularity":62}
         ]}
        """;

    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);
    private static readonly MarketSummary Us = new("US", "United States", "iphone", 2, null);

    [Fact]
    public async Task TheEnginesAnswerIsRead()
    {
        var client = new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("discover") });
        var report = await client.DiscoverAsync(1, "US", "iphone", ct: TestContext.Current.CancellationToken);
        Assert.Equal(["presentation"], report.Seeds);
        Assert.False(report.AppleAds);
        Assert.False(report.Jev);
        Assert.Equal(0, report.Measured);
        Assert.True(report.Candidates[0].Tracked);
        Assert.All(report.Candidates, c => Assert.Equal(["autocomplete"], c.Sources));
        Assert.All(report.Candidates, c => Assert.Null(c.Popularity));
    }

    [Fact]
    public async Task ArgumentsAndProgressFollowTheCommand()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Ok(Scored) };
        cli.ErrorLines.Add("""{"completed":0,"step":"Autocomplete \"notes\"","total":2}""");
        cli.ErrorLines.Add("not json");
        var progress = new ImmediateProgress<DiscoveryStep>();
        var client = new AsoClient(cli);
        var ct = TestContext.Current.CancellationToken;
        await client.DiscoverAsync(7, "US", "ipad", competitorId: 42, seeds: ["notes", "journal"], difficultyLimit: 10, progress, ct);
        await client.DiscoverAsync(7, "DE", "iphone", ct: ct);
        Assert.Equal(["--json", "discover", "7", "--country", "US", "--device", "ipad", "--competitor", "42", "--seeds", "notes,journal",
                      "--difficulty", "10"], cli.Calls[0]);
        Assert.Equal(["--json", "discover", "7", "--country", "DE", "--device", "iphone", "--difficulty", "25"], cli.Calls[1]);
        Assert.Equal(new DiscoveryStep("Autocomplete \"notes\"", 0, 2), Assert.Single(progress.Reports));
    }

    [Fact]
    public async Task FindingFillsTheTableAndAddingSkipsTrackedKeywords()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Command(args) == "keywords add"
            ? FakeCli.Ok("""{"market":"US · iphone","added":["notes app","notion"],"alreadyTracked":[]}""")
            : FakeCli.Ok(Scored);
        var status = new StatusViewModel();
        var vm = new DiscoveryViewModel(new AsoClient(cli), status, App, Us) { Seeds = "notes, Notes\n" };
        Assert.Equal("Find golden keywords", vm.Title);
        await vm.FindCommand.ExecuteAsync(null);
        Assert.Equal(["--seeds", "notes"], cli.Calls[0].SkipWhile(a => a != "--seeds").Take(2));
        Assert.Equal(["golden", "lead", "", "golden"], vm.Rows.Select(r => r.Mark));
        Assert.Equal(["55", "40", "< list", "62"], vm.Rows.Select(r => r.Popularity));
        Assert.Equal("brand", vm.Rows[2].Brand);
        Assert.Equal("autocomplete, ads suggestion", vm.Rows[0].Sources);
        Assert.StartsWith("4 candidate(s) · 2 with an Apple popularity value · 2 measured for difficulty · 1 golden", vm.Summary, StringComparison.Ordinal);
        Assert.Equal("", vm.Missing);
        Assert.Equal(["notes app"], vm.GoldenRows.Select(r => r.Keyword));   // the tracked golden one is not offered again

        Assert.False(vm.AddSelectedCommand.CanExecute(null));
        vm.SelectedRows = [vm.Rows[3]];
        Assert.False(vm.AddSelectedCommand.CanExecute(null));   // already tracked
        vm.SelectedRows = [vm.Rows[0], vm.Rows[2], vm.Rows[3]];
        await vm.AddSelectedCommand.ExecuteAsync(null);
        Assert.Equal(["--json", "keywords", "add", "361285480", "--country", "US", "--device", "iphone", "--", "notes app", "notion"], cli.Calls[^1]);
        Assert.Equal(2, vm.Added);
    }

    [Fact]
    public async Task MissingKeysAreExplainedAndCompetitorsNamed()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("discover") };
        var rival = new Competitor(42, "Rival Slides", "Rival Co", null, null, "Productivity", 900, 4.5, null, 3, 1, 4.5, []);
        var vm = new DiscoveryViewModel(new AsoClient(cli), new StatusViewModel(), App, Us, rival);
        Assert.Equal("Import keywords from Rival Slides", vm.Title);
        await vm.FindCommand.ExecuteAsync(null);
        Assert.Contains("--competitor", cli.Calls[0]);
        Assert.Contains("Apple Ads is not connected", vm.Missing, StringComparison.Ordinal);
        Assert.Contains("OpenRouter is not connected", vm.Missing, StringComparison.Ordinal);
        vm.ShowStep(new DiscoveryStep("Difficulty \"x\"", 1, 5));
        Assert.Equal("2/5  Difficulty \"x\"", vm.StepText);
        vm.ShowStep(new DiscoveryStep("Apple popularity lists", 0, 0));
        Assert.Equal("Apple popularity lists", vm.StepText);
    }

    [Fact]
    public void TheDialogNeedsAMarket()
    {
        var vm = new MainViewModel(new AsoClient(new FakeCli()));
        Assert.Null(vm.CreateDiscovery());
    }
}
