using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class ExpansionTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    // expand.json is the real engine's answer for Keynote's "keynote" and "slide deck" in GB and DE without keys; expand-candidates.json is
    // the engine against the engine tests' fakes (Apple's list, local forms for Germany, --track).
    private static readonly AppRecord Keynote = new(361285480, "com.apple.Keynote", "Keynote: Design Presentations", "Apple", null, null, null,
                                                    DateTimeOffset.UnixEpoch);
    private static readonly MarketSummary Us = new("US", "United States", "iphone", 3, null);

    private static IReadOnlyList<StorefrontInfo> Storefronts { get; } =
        [new("US", "United States", "en-US"), new("GB", "United Kingdom", "en-GB"), new("DE", "Germany", "de-DE"), new("TR", "Türkiye", "tr")];

    [Fact]
    public async Task TheReportIsReadWithProgress()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("expand") };
        cli.ErrorLines.Add("""{"completed":0,"country":"GB","step":"“keynote”","total":4}""");
        var steps = new ImmediateProgress<ExpansionStep>();
        var report = await new AsoClient(cli).ExpandAsync(361285480, "US", "iphone", ["GB", "DE"], [], localForms: true, track: false, steps, Ct);
        Assert.Equal(["--json", "expand", "361285480", "--from", "US", "--device", "iphone", "--countries", "GB,DE"], cli.Calls[0]);
        Assert.Equal("GB", steps.Reports.Single().Country);
        Assert.Equal((2, false, false), (report.Keywords, report.AppleAds, report.LanguageChecked));
        Assert.Equal(4, report.Rows.Count);
        var first = report.Rows[0];
        Assert.Equal(("GB", "keynote", 1, "Keynote: Design Presentations"), (first.Country, first.Term, first.Rank, first.Leader));
        Assert.Null(first.Popularity);

        await new AsoClient(cli).ExpandAsync(1, "US", "ipad", ["DE"], ["notes", "journal"], localForms: false, track: true, ct: Ct);
        Assert.Equal(["--json", "expand", "1", "--from", "US", "--device", "ipad", "--countries", "DE", "--keywords", "notes,journal", "--no-local-forms",
                      "--track"], cli.Calls[^1]);
    }

    [Fact]
    public async Task TheDialogTriesTheChosenCountriesAndFiltersCandidates()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("expand-candidates") };
        var refreshed = 0;
        var vm = new ExpansionViewModel(new AsoClient(cli), Keynote, Us, Storefronts, () => { refreshed++; return Task.CompletedTask; });
        Assert.Equal("Try Keynote's keywords in other countries", vm.Title);
        Assert.Equal(["GB", "DE", "TR"], vm.Countries.Select(c => c.Storefront.Code));
        Assert.Equal(["GB", "DE"], vm.ChosenCountries);
        Assert.StartsWith("3 keyword(s) × 2 storefront(s)", vm.Estimate, StringComparison.Ordinal);
        vm.Keywords = "notes, journal";
        Assert.Equal(["notes", "journal"], vm.KeywordList);

        await vm.RunCommand.ExecuteAsync(null);
        Assert.Contains("--track", cli.Calls[^1]);
        Assert.Contains("notes,journal", cli.Calls[^1]);
        Assert.Equal(1, refreshed);
        Assert.StartsWith("2 keyword(s) × 2 storefront(s):", vm.Summary, StringComparison.Ordinal);
        Assert.Contains("cell(s) tracked", vm.Summary, StringComparison.Ordinal);
        var notizen = vm.Rows.Single(r => r.Keyword == "notizen");
        Assert.Equal(("DE", "for “notes” · notes", "40", "tracked"), (notizen.Country, notizen.From, notizen.Popularity, notizen.Tracked));
        var all = vm.Rows.Count;
        vm.CandidatesOnly = true;
        Assert.True(vm.Rows.Count <= all);
        Assert.All(vm.Rows, r => Assert.Equal("★", r.Mark));
    }

    [Fact]
    public async Task NoCountryIsAnErrorAndMissingKeysAreExplained()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("expand") };
        var vm = new ExpansionViewModel(new AsoClient(cli), Keynote, Us, Storefronts, () => Task.CompletedTask);
        foreach (var c in vm.Countries) c.IsSelected = false;
        await vm.RunCommand.ExecuteAsync(null);
        Assert.Equal("Choose at least one storefront.", vm.Error);
        Assert.Empty(cli.Calls);

        vm.Countries[0].IsSelected = true;
        await vm.RunCommand.ExecuteAsync(null);
        Assert.Null(vm.Error);
        Assert.Contains("Apple Ads is not connected", vm.Missing, StringComparison.Ordinal);
        Assert.Contains("OpenRouter is not connected", vm.Missing, StringComparison.Ordinal);
        Assert.Equal(("#1", "", "37"), vm.Rows.Where(r => r.Country == "GB" && r.Keyword == "keynote").Select(r => (r.Rank, r.Popularity, r.Difficulty)).Single());
    }
}
