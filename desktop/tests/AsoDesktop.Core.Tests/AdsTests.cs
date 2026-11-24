using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class AdsTests
{
    // ads-list-empty.json is the real engine's answer before any sync; Synced has the shape of one after a sync, which the
    // engine's own tests pin (reading campaigns needs Apple Ads keys).
    private const string Synced = """
        {"syncedAt":"2026-10-24T09:00:00Z","periodStart":"2026-09-24T09:00:00Z","periodEnd":"2026-10-24T09:00:00Z",
         "storefronts":[{"country":"US","countryName":"United States","impressions":1000,"taps":70,"installs":25,"spend":40,"currency":"USD",
                         "costPerInstall":1.6,"tapToInstall":0.35714285714285715},
                        {"country":"DE","countryName":"Germany","impressions":50,"taps":0,"installs":0,"spend":1.25,"currency":"USD"}],
         "keywords":[{"campaignID":1,"campaignName":"Acme US","adGroupName":"Group","keywordID":900,"keyword":"Notes","matchType":"EXACT",
                      "status":"ACTIVE","country":"US","bid":1.5,"currency":"USD","impressions":900,"taps":60,"installs":20,"spend":30,
                      "periodStart":"2026-09-24T09:00:00Z","periodEnd":"2026-10-24T09:00:00Z","fetchedAt":"2026-10-24T09:00:00Z"}]}
        """;

    private static readonly AppRecord App = new(361285480, null, "Keynote", "Apple Inc.", null, null, null, DateTimeOffset.UnixEpoch);

    [Fact]
    public async Task ReportsAreReadBeforeAndAfterASync()
    {
        var empty = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("ads-list-empty") }).AdsAsync(1, TestContext.Current.CancellationToken);
        Assert.Null(empty.SyncedAt);
        Assert.Empty(empty.Storefronts);

        var report = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Ok(Synced) }).AdsAsync(1, TestContext.Current.CancellationToken);
        Assert.Equal(["US", "DE"], report.Storefronts.Select(s => s.Country));
        Assert.Null(report.Storefronts[1].CostPerInstall);
        Assert.Equal(("Acme US", 900), (report.Keywords[0].CampaignName, report.Keywords[0].Impressions));
    }

    [Fact]
    public async Task TheCardSyncsOnlyWhenConnectedAndShowsStorefronts()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Command(args) == "ads sync"
            ? FakeCli.Ok("""{"campaigns":2,"matched":1,"rows":3,"periodStart":"2026-09-24T09:00:00Z","periodEnd":"2026-10-24T09:00:00Z"}""")
            : FakeCli.Ok(Synced);
        var status = new StatusViewModel();
        var synced = 0;
        var vm = new AdsViewModel(new AsoClient(cli), status) { Synced = () => { synced++; return Task.CompletedTask; } };
        Assert.False(vm.SyncCommand.CanExecute(null));
        vm.App = App;
        await vm.ReloadAsync();
        Assert.True(vm.HasRows);
        Assert.Equal("United States (US)", vm.Rows[0].Storefront);
        Assert.Equal("—", vm.Rows[1].TapToInstall);
        Assert.StartsWith("2026-09-24 to 2026-10-24, synced ", vm.Headline, StringComparison.Ordinal);

        vm.AdsConnected = true;
        await vm.SyncCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "ads", "sync", "--days", "30"]));
        Assert.Equal("2 campaign(s) in the account, 1 for tracked apps; 3 keyword × storefront row(s) for the last 30 days.", status.Message);
        Assert.Equal(1, synced);
    }

    [Fact]
    public async Task BeforeASyncTheCardSaysWhatItIsFor()
    {
        var vm = new AdsViewModel(new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("ads-list-empty") }), new StatusViewModel()) { App = App };
        await vm.ReloadAsync();
        Assert.False(vm.HasRows);
        Assert.StartsWith("Your own campaign results", vm.Headline, StringComparison.Ordinal);
    }

    [Fact]
    public void KeywordsShowTheirOwnResults()
    {
        var withAds = new KeywordRow(new KeywordReportRow("notes", "US", "iphone", "found", 3, 200, "#3", null, "", null, null, null, false, false,
                                                          null, null, Ads: new AdsTotals(1200, 70, 25, 40, "USD")));
        var without = new KeywordRow(withAds.Report with { Ads = null });
        Assert.Equal($"{1200.ToString("N0", System.Globalization.CultureInfo.CurrentCulture)} · 70 taps · 25 inst.", withAds.Ads);
        Assert.Equal(("", -1), (without.Ads, without.AdsOrder));
        Assert.Equal(1200, withAds.AdsOrder);
    }
}
