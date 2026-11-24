using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class RevenueTests
{
    // revenue-show-none.json is the real engine's answer when no project matches; Matched has the shape of one that does,
    // which the engine's own tests pin (reading RevenueCat needs a secret key).
    private const string Matched = """
        {"match":"bundleID","mrrChange":20,
         "latest":{"projectID":"p1","projectName":"Acme","bundleIDs":["com.acme.notes"],"appNames":["Acme Notes","Acme Diary"],"mrr":1230.4,
                   "activeSubscriptions":310,"revenue28d":1105.6,"newCustomers28d":44,"activeTrials":12,"activeUsers28d":900,
                   "fetchedAt":"2026-10-24T09:00:00Z"},
         "history":[{"projectID":"p1","projectName":"Acme","bundleIDs":["com.acme.notes"],"appNames":["Acme Notes","Acme Diary"],"mrr":1230.4,
                     "activeSubscriptions":310,"revenue28d":1105.6,"newCustomers28d":44,"activeTrials":12,"activeUsers28d":900,
                     "fetchedAt":"2026-10-24T09:00:00Z"},
                    {"projectID":"p1","projectName":"Acme","bundleIDs":["com.acme.notes"],"appNames":["Acme Notes","Acme Diary"],"mrr":1210,
                     "activeSubscriptions":305,"revenue28d":1090,"newCustomers28d":40,"activeTrials":10,"activeUsers28d":880,
                     "fetchedAt":"2026-10-23T09:00:00Z"}]}
        """;

    private static readonly AppRecord App = new(361285480, "com.acme.notes", "Acme Notes", "Acme", null, null, null, DateTimeOffset.UnixEpoch);

    [Fact]
    public async Task ReportsAreReadWithAndWithoutAMatch()
    {
        var none = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("revenue-show-none") }).RevenueAsync(1, TestContext.Current.CancellationToken);
        Assert.Null(none.Match);
        Assert.Null(none.Latest);
        Assert.Empty(none.History);

        var cli = new FakeCli { Respond = _ => FakeCli.Ok(Matched) };
        var report = await new AsoClient(cli).RevenueAsync(7, TestContext.Current.CancellationToken);
        Assert.Equal(["--json", "revenue", "show", "7"], cli.Calls[0]);
        Assert.Equal(("bundleID", 310, 20.0), (report.Match, report.Latest!.ActiveSubscriptions, report.MrrChange!.Value));
        Assert.Equal(["com.acme.notes"], report.Latest.BundleIds);
        Assert.Equal(2, report.History.Count);
    }

    [Fact]
    public async Task TheCardShowsTheProjectAndRefreshesOnlyWhenConnected()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Command(args) == "revenue refresh" ? FakeCli.Ok("""{"projects":2,"failures":["RevenueCat rejected the credentials (401/403)."]}""")
                                                                        : FakeCli.Ok(Matched);
        var status = new StatusViewModel();
        var vm = new RevenueViewModel(new AsoClient(cli), status);
        Assert.False(vm.RefreshCommand.CanExecute(null));
        Assert.StartsWith("Add RevenueCat secret API keys", vm.Headline, StringComparison.Ordinal);

        vm.RevenueConnected = true;
        vm.App = App;
        await vm.ReloadAsync();
        Assert.True(vm.HasLatest);
        Assert.True(vm.HasHistory);
        Assert.Equal(RevenueViewModel.Dollars(1230.4), vm.Mrr);
        Assert.Equal("+" + RevenueViewModel.Dollars(20), vm.MrrChange);
        Assert.Contains("the project holds 2 apps (Acme Notes, Acme Diary)", vm.Headline, StringComparison.Ordinal);
        Assert.Equal(RevenueViewModel.Dollars(1105.6), vm.Revenue);

        await vm.RefreshCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "revenue", "refresh"]));
        Assert.Equal("2 RevenueCat project(s) read. 1 key(s) failed: RevenueCat rejected the credentials (401/403).", status.Message);
    }

    [Fact]
    public async Task WithoutAMatchTheCardSaysHowProjectsAreFound()
    {
        var vm = new RevenueViewModel(new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("revenue-show-none") }), new StatusViewModel())
        {
            RevenueConnected = true,
            App = App,
        };
        await vm.ReloadAsync();
        Assert.False(vm.HasLatest);
        Assert.Equal("No RevenueCat project matches this app (bundle com.acme.notes). Press Refresh; projects are matched by bundle ID, then by name.",
                     vm.Headline);
        Assert.Equal("", vm.MrrChange);
    }

    [Fact]
    public void DollarsAreWhole()
    {
        Assert.Equal("$" + 1230.ToString("N0", System.Globalization.CultureInfo.CurrentCulture), RevenueViewModel.Dollars(1230.4));
        Assert.Equal("$0", RevenueViewModel.Dollars(0.2));
    }
}
