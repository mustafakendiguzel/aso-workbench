using System.Globalization;
using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class SettingsContractTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task SettingsAreRead()
    {
        var settings = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("settings") }).SettingsAsync(Ct);
        Assert.Equal(200, settings.ResultDepth);
        Assert.Equal(2.5, settings.PacingSeconds);
        Assert.Equal((30, 45, 35, 55), (settings.GoldenMinPopularity, settings.GoldenMaxDifficulty, settings.WriterEasyDifficulty, settings.WriterMaxDifficulty));
        Assert.Equal("lastMarker", settings.DeltaReference);
        Assert.Equal("", settings.AdsReferenceAppId);
    }

    [Fact]
    public async Task ConnectionsShowIdentifiersButNoSecret()
    {
        var connections = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("connections") }).ConnectionsAsync(Ct);
        Assert.Equal(["apple-ads", "asc", "openrouter", "revenuecat"], connections.Select(c => c.Service));
        var asc = connections[1];
        Assert.True(asc.Configured);
        Assert.Equal("TESTKEY123", asc.Details["keyID"]);
        Assert.Equal("a40f0f2e2974dc76", asc.Details["keyFingerprint"]);
        Assert.False(connections[0].Configured);
        Assert.Empty(connections[0].Details);
        Assert.DoesNotContain("sk-or-v1", File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "connections.json")), StringComparison.Ordinal);
    }
}

public sealed class ConnectionClientTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;
    private static FakeCli Cli() => new() { Respond = _ => FakeCli.Ok("""{"service":"x","title":"X","configured":true,"details":{}}""") };

    [Fact]
    public async Task SecretsTravelThroughStdinNeverAsArguments()
    {
        var cli = Cli();
        var client = new AsoClient(cli);
        await client.SaveOpenRouterKeyAsync("sk-or-v1-secret", Ct);
        await client.SaveRevenueCatKeysAsync("sk_a\nsk_b", Ct);
        await client.SaveAppleAdsAsync("SEARCHADS.c", "K", "O", KeySource.Pasted("-----BEGIN PRIVATE KEY-----"), Ct);

        Assert.Equal(["--json", "connections", "set", "openrouter", "--key-stdin"], cli.Calls[0]);
        Assert.Equal("sk-or-v1-secret", cli.Inputs[0]);
        Assert.Equal("sk_a\nsk_b", cli.Inputs[1]);
        Assert.Contains("--key-stdin", cli.Calls[2]);
        Assert.Equal("-----BEGIN PRIVATE KEY-----", cli.Inputs[2]);
        Assert.All(cli.Calls, call => Assert.DoesNotContain(call, a => a.Contains("secret", StringComparison.Ordinal) || a.Contains("PRIVATE", StringComparison.Ordinal)));
    }

    [Fact]
    public async Task KeyFilesArePassedAsPathsForAsoToRead()
    {
        var cli = Cli();
        await new AsoClient(cli).SaveAppStoreConnectAsync(null, "issuer", KeySource.File("/keys/AuthKey_ABC.p8"), Ct);
        Assert.Equal(["--json", "connections", "set", "asc", "--issuer-id", "issuer", "--key-file", "/keys/AuthKey_ABC.p8"], cli.Calls[0]);
        Assert.Null(cli.Inputs[0]);
    }

    [Fact]
    public async Task SettingValuesFollowDoubleDashAndStaleMeasureNeedsNoApp()
    {
        var cli = new FakeCli { Respond = args => args.Contains("measure") ? FakeCli.Fixture("measure") : FakeCli.Fixture("settings") };
        var client = new AsoClient(cli);
        await client.SetSettingAsync("adsReferenceAppID", "-1", Ct);
        await client.MeasureStaleAsync(ct: Ct);
        Assert.Equal(["--json", "settings", "set", "adsReferenceAppID", "--", "-1"], cli.Calls[0]);
        Assert.Equal(["--json", "measure", "--stale"], cli.Calls[1]);
    }

    [Fact]
    public async Task VerifyReturnsTheServiceAnswer()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Ok("""{"result":"Token OK; sample query returned data.","service":"apple-ads"}""") };
        Assert.Equal("Token OK; sample query returned data.", await new AsoClient(cli).VerifyConnectionAsync("apple-ads", Ct));
        Assert.Equal(["--json", "connections", "verify", "apple-ads"], cli.Calls[0]);
    }
}

public sealed class SettingsViewModelTests
{
    private static (SettingsViewModel, FakeCli, StatusViewModel) Make()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Command(args) switch
        {
            "connections" => FakeCli.Fixture("connections"),
            _ => FakeCli.Fixture("settings"),
        };
        var status = new StatusViewModel();
        return (new SettingsViewModel(new AsoClient(cli), status), cli, status);
    }

    [Fact]
    public async Task LoadingShowsSettingsAndConnectionStates()
    {
        var (vm, _, _) = Make();
        await vm.LoadCommand.ExecuteAsync(null);
        Assert.Equal(2.5, vm.PacingSeconds);
        Assert.Equal("lastMarker", vm.DeltaReference);
        Assert.True(vm.AppStoreConnect.IsConfigured);
        Assert.Equal("issuerID 00000000-0000-0000-0000-000000000000 · keyFingerprint a40f0f2e2974dc76 · keyID TESTKEY123", vm.AppStoreConnect.Details);
        Assert.False(vm.AppleAds.IsConfigured);
        Assert.Equal("Not set", vm.AppleAds.StatusText);
        Assert.True(vm.OpenRouter.TestCommand.CanExecute(null));
        Assert.False(vm.RevenueCat.RemoveCommand.CanExecute(null));
    }

    [Fact]
    public async Task SavingSendsOnlyChangesInInvariantFormat()
    {
        var culture = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = new CultureInfo("tr-TR");   // decimal comma: "2,5" must not reach the engine
        try
        {
            var (vm, cli, status) = Make();
            await vm.LoadCommand.ExecuteAsync(null);
            cli.Calls.Clear();
            vm.PacingSeconds = 4.2;
            vm.AutoMeasureOnLaunch = true;
            await vm.SaveCommand.ExecuteAsync(null);

            Assert.Equal([["--json", "settings", "set", "pacingSeconds", "--", "4.2"], ["--json", "settings", "set", "autoMeasureOnLaunch", "--", "true"]],
                         cli.Calls.Select(c => c.ToArray()));
            Assert.Equal("Saved 2 setting(s).", status.Message);
        }
        finally
        {
            CultureInfo.CurrentCulture = culture;
        }
    }

    [Fact]
    public async Task NothingChangedSendsNothing()
    {
        var (vm, cli, status) = Make();
        await vm.LoadCommand.ExecuteAsync(null);
        var before = cli.Calls.Count;
        await vm.SaveCommand.ExecuteAsync(null);
        Assert.Equal(before, cli.Calls.Count);
        Assert.Equal("Nothing changed.", status.Message);
    }

    [Fact]
    public async Task ConnectionsNeedTheirFieldsAndForgetSecretsAfterSaving()
    {
        var (vm, cli, _) = Make();
        await vm.LoadCommand.ExecuteAsync(null);
        Assert.False(vm.AppleAds.SaveCommand.CanExecute(null));
        vm.AppleAds.ClientId = "SEARCHADS.c";
        vm.AppleAds.KeyId = "K";
        vm.AppleAds.OrgId = "1";
        Assert.False(vm.AppleAds.SaveCommand.CanExecute(null));
        vm.AppleAds.KeyFilePath = "/keys/ads.pem";
        Assert.True(vm.AppleAds.SaveCommand.CanExecute(null));

        cli.Respond = _ => FakeCli.Ok("""{"service":"openrouter","title":"OpenRouter","configured":true,"details":{"key":"stored"}}""");
        vm.OpenRouter.ApiKey = "sk-or-v1-secret";
        await vm.OpenRouter.SaveCommand.ExecuteAsync(null);
        Assert.Equal("", vm.OpenRouter.ApiKey);
        Assert.True(vm.OpenRouter.IsConfigured);
        Assert.Equal("sk-or-v1-secret", cli.Inputs[^1]);
    }

    [Fact]
    public async Task TestingShowsTheAnswerAndFailuresGoToTheStatusLine()
    {
        var (vm, cli, status) = Make();
        await vm.LoadCommand.ExecuteAsync(null);
        cli.Respond = _ => FakeCli.Ok("""{"result":"Jev answered.","service":"openrouter"}""");
        await vm.OpenRouter.TestCommand.ExecuteAsync(null);
        Assert.Equal("Jev answered.", vm.OpenRouter.LastTest);

        cli.Respond = _ => new CliResult(1, "", "error: OpenRouter rejected the credentials (401/403).\n");
        await vm.OpenRouter.TestCommand.ExecuteAsync(null);
        Assert.Null(vm.OpenRouter.LastTest);
        Assert.True(status.IsError);
        Assert.Equal("OpenRouter rejected the credentials (401/403).", status.Message);
    }

    [Fact]
    public void GuidesSayWhatThisVersionDoes()
    {
        foreach (var guide in new[] { ConnectionGuides.AppleAds, ConnectionGuides.AppStoreConnect, ConnectionGuides.OpenRouter, ConnectionGuides.RevenueCat })
        {
            Assert.NotEmpty(guide.Unlocks);
            Assert.NotEmpty(guide.Steps);
            Assert.StartsWith("https://", guide.Link, StringComparison.Ordinal);
            Assert.DoesNotContain("Mac", guide.DataFlow, StringComparison.Ordinal);
        }
        // Apple Ads powers popularity, OpenRouter the discovery checks and RevenueCat revenue; App Store Connect is stored and tested only.
        Assert.StartsWith("This version reads popularity", ConnectionGuides.AppleAds.Availability, StringComparison.Ordinal);
        Assert.StartsWith("This version uses the key for the brand", ConnectionGuides.OpenRouter.Availability, StringComparison.Ordinal);
        Assert.StartsWith("This version reads revenue", ConnectionGuides.RevenueCat.Availability, StringComparison.Ordinal);
        Assert.Equal(ConnectionGuide.NotYetUsed, ConnectionGuides.AppStoreConnect.Availability);
    }
}

public sealed class StartupTests
{
    [Fact]
    public async Task AutoMeasureRunsOnlyWhenTheSettingIsOn()
    {
        foreach (var on in new[] { false, true })
        {
            var cli = new FakeCli();
            var settings = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "settings.json"))
                .Replace("\"autoMeasureOnLaunch\" : false", $"\"autoMeasureOnLaunch\" : {(on ? "true" : "false")}", StringComparison.Ordinal);
            cli.Respond = args => FakeCli.Command(args) switch
            {
                "settings" => FakeCli.Ok(settings),
                "connections" => FakeCli.Fixture("connections"),
                "measure" => FakeCli.Fixture("measure"),
                "app list" => FakeCli.Ok("[]"),
                _ => FakeCli.Fixture("version"),
            };
            var vm = new MainViewModel(new AsoClient(cli));
            await vm.LoadCommand.ExecuteAsync(null);
            Assert.Equal(on, cli.Calls.Any(c => c.SequenceEqual(["--json", "measure", "--stale"])));
            if (on) Assert.StartsWith("Refreshed 2 keyword(s)", vm.Status.Message, StringComparison.Ordinal);
        }
    }
}
