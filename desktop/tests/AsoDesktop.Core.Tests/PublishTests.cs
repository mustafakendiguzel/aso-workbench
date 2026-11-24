using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class PublishTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    // The fixtures are the real engine's answers with App Store Connect replaced by the engine tests' fake: en-US live on version
    // 2.0, drafts for en-US (changed), de-DE (new on App Store Connect) and fr-FR (a name over the limit).
    private static readonly AppRecord Acme = new(1000001, "com.example.1000001", "Acme Notes", "Acme Inc", null, null, null, DateTimeOffset.UnixEpoch);

    private static FakeCli Cli(string versions = """[{"editable":true,"id":"v2","state":"PREPARE_FOR_SUBMISSION","version":"2.0"}]""") => new()
    {
        Respond = args => FakeCli.Command(args) switch
        {
            "metadata versions" => FakeCli.Ok(versions),
            "metadata plan" => FakeCli.Fixture(args.Contains("--all") ? "metadata-plan-all" : "metadata-plan"),
            "metadata apply" => FakeCli.Fixture("metadata-apply"),
            "metadata apply-all" => FakeCli.Fixture("metadata-apply-all"),
            "metadata create-version" => FakeCli.Ok("""{"editable":true,"id":"v-2.1","state":"PREPARE_FOR_SUBMISSION","version":"2.1"}"""),
            _ => FakeCli.Ok("{}"),
        },
    };

    private static int CallsTo(FakeCli cli, string command) => cli.Calls.Count(c => FakeCli.Command(c) == command);

    [Fact]
    public async Task PublishingAnswersAreRead()
    {
        var pull = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("metadata-pull") }).PullMetadataAsync(1, Ct);
        Assert.Equal(["en-US"], pull.Locales);
        Assert.Equal(("2.0", true, "https://example.com/privacy"), (pull.Version, pull.Editable, pull.PrivacyUrl));

        var plans = await new AsoClient(Cli()).PublishPlansAsync(1, "en-US", Ct);
        Assert.Equal([("de-DE", false, true), ("en-US", true, true), ("fr-FR", false, false)], plans.Select(p => (p.Locale, p.Exists, p.IsReady)));
        Assert.Equal(["name", "subtitle", "keywords", "description", "whatsNew"], plans[0].Changes.Select(c => c.Field));
        Assert.Equal(ValidationSeverity.Error, plans[2].Errors[0].Severity);
        Assert.Equal(2, plans[2].Automatic.Count);

        var applied = await new AsoClient(Cli()).PublishAllAsync(1, ["de-DE"], "en-US", Ct);
        Assert.True(applied[0].Succeeded);
        Assert.Equal(6, applied[0].Screenshots!.Copied);

        var log = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("metadata-log") }).ChangeLogAsync(1, Ct);
        Assert.Equal(["de-DE", "en-US"], log.Select(e => e.Locale));
        Assert.All(log, e => Assert.Equal("applied", e.Status));

        var markers = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("markers-list-change") }).MarkersAsync(1, Ct);
        Assert.Equal(["Published", "Published"], markers.Select(m => new MarkerLine(m).Kind));
        Assert.StartsWith("Applied Subtitle, Keywords, Description", markers[^1].Title, StringComparison.Ordinal);
    }

    [Fact]
    public async Task OnlyPublishingConfirmsTheWrite()
    {
        var cli = Cli();
        var client = new AsoClient(cli);
        await client.PublishPlanAsync(1, "de-DE", createMissing: true, copyScreenshotsFrom: "en-US", Ct);
        Assert.Equal(["--json", "metadata", "plan", "1", "--locale", "de-DE", "--create-missing", "--copy-screenshots-from", "en-US"], cli.Calls[^1]);
        await client.PublishAsync(1, "en-US", createMissing: false, copyScreenshotsFrom: null, Ct);
        Assert.Equal(["--json", "metadata", "apply", "1", "--locale", "en-US", "--yes"], cli.Calls[^1]);
        await client.CreateVersionAsync(1, "2.1", Ct);
        Assert.Equal(["--json", "metadata", "create-version", "1", "2.1", "--yes"], cli.Calls[^1]);
        Assert.DoesNotContain(cli.Calls.Where(c => FakeCli.Command(c) is "metadata plan" or "metadata versions"), c => c.Contains("--yes"));
    }

    [Fact]
    public async Task ARefusedWriteIsAResultAndAnErrorIsAnException()
    {
        var refused = new FakeCli
        {
            Respond = _ => new CliResult(1, """{"changes":[],"locale":"en-US","message":"Nothing to apply.","status":"refused"}""",
                                         "error: en-US was not applied."),
        };
        var result = await new AsoClient(refused).PublishAsync(1, "en-US", false, null, Ct);
        Assert.Equal(("refused", false), (result.Status, result.Succeeded));

        var broken = new FakeCli { Respond = _ => new CliResult(1, "", "error: App Store Connect is not connected.") };
        var error = await Assert.ThrowsAsync<AsoCliException>(() => new AsoClient(broken).PublishAsync(1, "en-US", false, null, Ct));
        Assert.Equal("App Store Connect is not connected.", error.Message);
    }

    [Fact]
    public async Task TheDialogPlansFirstAndPublishesOnlyReadyLocales()
    {
        var cli = Cli();
        var published = 0;
        var vm = new PublishViewModel(new AsoClient(cli), Acme, null, ["en-US"], () => { published++; return Task.CompletedTask; });
        await vm.LoadAsync();

        Assert.Equal(0, CallsTo(cli, "metadata apply-all"));
        Assert.Equal("Version 2.0 (PREPARE_FOR_SUBMISSION) takes the listing; the live version stays as it is.", vm.VersionText);
        Assert.False(vm.NeedsVersion);
        Assert.True(vm.HasNewLocales);
        Assert.False(vm.CanChooseCreateMissing);
        Assert.Equal([true, true, false], vm.Lines.Select(l => l.IsSelected));
        var french = vm.Lines[2];
        Assert.Equal("The draft has validation errors. Fix them before applying.", french.Summary);
        french.IsSelected = true;
        Assert.False(french.IsSelected);
        Assert.Equal(2, vm.SelectedCount);
        Assert.Equal("Journal and diary", vm.Lines[1].Changes[0].BeforeText);

        vm.Lines[1].IsSelected = false;
        vm.CopyScreenshotsFrom = "en-US";
        Assert.Contains("--copy-screenshots-from", cli.Calls[^1]);
        vm.Lines[1].IsSelected = false;

        await vm.PublishCommand.ExecuteAsync(null);
        var write = cli.Calls.Single(c => FakeCli.Command(c) == "metadata apply-all");
        Assert.Equal(["--json", "metadata", "apply-all", "1000001", "--locales", "de-DE", "--copy-screenshots-from", "en-US", "--yes"], write);
        Assert.True(vm.IsDone);
        Assert.False(vm.PublishCommand.CanExecute(null));
        Assert.Equal(1, published);
        Assert.True(vm.Lines[0].Succeeded);
        Assert.Contains("Screenshots: 6 copied", vm.Lines[0].ResultText, StringComparison.Ordinal);
        Assert.Equal("Published 1 locale(s) to App Store Connect and read them back.", vm.Outcome);
    }

    [Fact]
    public async Task WithoutAnEditableVersionTheNextOneIsCreatedFirst()
    {
        var cli = Cli("""[{"editable":false,"id":"v1","state":"READY_FOR_SALE","version":"2.0"}]""");
        var vm = new PublishViewModel(new AsoClient(cli), Acme, "en-US", [], () => Task.CompletedTask);
        await vm.LoadAsync();
        Assert.True(vm.NeedsVersion);
        Assert.StartsWith("No version can be edited: 2.0 is READY_FOR_SALE.", vm.VersionText, StringComparison.Ordinal);
        Assert.False(vm.CreateVersionCommand.CanExecute(null));
        vm.NewVersion = " 2.1 ";
        await vm.CreateVersionCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "metadata", "create-version", "1000001", "2.1", "--yes"]));
        Assert.Equal("Created version 2.1 (PREPARE_FOR_SUBMISSION).", vm.Outcome);
        Assert.Equal(2, CallsTo(cli, "metadata plan"));
        Assert.Equal(["--json", "metadata", "plan", "1000001", "--locale", "en-US", "--create-missing"], cli.Calls.First(c => FakeCli.Command(c) == "metadata plan"));
    }

    [Fact]
    public async Task PullingNeedsTheKeyAndReadsTheEditorAgain()
    {
        var cli = new FakeCli
        {
            Respond = args => FakeCli.Command(args) switch
            {
                "locales" => FakeCli.Fixture("locales"),
                "metadata locales" => FakeCli.Fixture("metadata-locales"),
                "metadata show" => FakeCli.Fixture("metadata-show"),
                "metadata pull" => FakeCli.Fixture("metadata-pull"),
                _ => FakeCli.Ok("{}"),
            },
        };
        var status = new StatusViewModel();
        var vm = new MetadataViewModel(new AsoClient(cli), status) { SaveDelay = TimeSpan.Zero, App = Acme };
        await vm.LoadLocalesAsync();
        vm.SelectedLocale = vm.Locales.First(l => l.Locale == "en-US");
        await vm.ReloadAsync();

        Assert.False(vm.PullCommand.CanExecute(null));
        Assert.Contains("Settings → Connections", vm.AscHint, StringComparison.Ordinal);
        vm.AscConnected = true;
        Assert.True(vm.PullCommand.CanExecute(null));
        var shows = CallsTo(cli, "metadata show");
        await vm.PullCommand.ExecuteAsync(null);
        Assert.Equal(1, CallsTo(cli, "metadata pull"));
        Assert.True(CallsTo(cli, "metadata show") > shows);
        Assert.StartsWith("Pulled 1 locale(s) from App Store Connect: version 2.0 (PREPARE_FOR_SUBMISSION), editable.", status.Message, StringComparison.Ordinal);

        var publish = await vm.CreatePublishAsync(everyDraft: false);
        Assert.Equal("Publish en-US of Acme Notes", publish!.Title);
        Assert.Equal([PublishViewModel.NoCopy], publish.CopySources);
    }
}
