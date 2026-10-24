using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class WriterTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    // The fixtures are the real engine's answers with the model replaced by the engine tests' scripted one: Acme Notes tracked in the
    // US (two keywords) and Germany, where the model fails.
    private static readonly AppRecord Acme = new(1000001, "com.example.1000001", "Acme Notes: Daily Journal", "Acme Inc", null, null, null,
                                                 DateTimeOffset.UnixEpoch);

    private static FakeCli Cli() => new()
    {
        Respond = args => FakeCli.Command(args) switch
        {
            "metadata write" => FakeCli.Fixture("metadata-write"),
            "metadata improve" => FakeCli.Fixture("metadata-improve"),
            "metadata write-all" => FakeCli.Fixture("metadata-write-all"),
            "metadata whats-new" => FakeCli.Fixture("metadata-whats-new"),
            "locales" => FakeCli.Fixture("locales"),
            "metadata locales" => FakeCli.Fixture("metadata-locales"),
            "metadata show" or "metadata draft" => FakeCli.Fixture("metadata-show"),
            _ => FakeCli.Ok("{}"),
        },
    };

    [Fact]
    public async Task WriterAnswersAreRead()
    {
        var client = new AsoClient(Cli());
        var written = await client.WriteAsync(1, "en-US", brandFirst: false, brand: null, notes: null, rewriteCopy: false, Ct);
        Assert.Equal(("US", "$0.0020", false), (written.Market, written.Cost, written.Saved));
        Assert.Equal(["A", "B"], written.Proposals.Select(p => p.Label));
        Assert.Equal((90, 104), (written.Proposals[0].Score, written.Proposals[0].CharactersUsed));
        Assert.Equal(["notes", "daily journal"], written.Proposals[0].Covered);
        Assert.Equal("warning", written.Proposals[0].Findings[0].Kind);

        var improved = await client.ImproveAsync(1, "en-US", null, Ct);
        Assert.True(improved.Saved);
        Assert.Equal("Improved", improved.Proposal.Label);

        var all = await client.WriteAllAsync(1, ["de-DE", "en-US"], false, null, null, ct: Ct);
        Assert.Null(all[0].Proposal);
        Assert.Equal("Network error: offline", all[0].Error);
        Assert.Equal("Acme Notes: Daily Journal", all[1].Proposal!.Fields.Name);

        var notes = await client.WriteWhatsNewAsync(1, "en-US", "Bug fixes.", ["en-GB", "fr-FR"], Ct);
        Assert.Equal([("en-GB", "Bug fixes."), ("fr-FR", "Corrections.")], notes.Select(n => (n.Locale, n.Text)));
    }

    [Fact]
    public async Task OptionsAndTextReachTheCommand()
    {
        var cli = Cli();
        cli.ErrorLines.Add("""{"locale":"de-DE"}""");
        cli.ErrorLines.Add("Writing en-US…");
        var client = new AsoClient(cli);
        await client.WriteAsync(1, "de-DE", brandFirst: true, brand: "Acme", notes: "Calm tone.", rewriteCopy: true, Ct);
        Assert.Equal(["--json", "metadata", "write", "1", "--locale", "de-DE", "--strategy", "brand", "--brand", "Acme", "--notes", "Calm tone.",
                      "--rewrite-copy"], cli.Calls[^1]);
        await client.ImproveAsync(1, "en-US", null, Ct);
        Assert.Equal(["--json", "metadata", "improve", "1", "--locale", "en-US", "--save"], cli.Calls[^1]);
        var steps = new ImmediateProgress<string>();
        await client.WriteAllAsync(1, ["de-DE", "en-US"], false, null, null, steps, Ct);
        Assert.Equal(["--json", "metadata", "write-all", "1", "--locales", "de-DE,en-US", "--strategy", "feature"], cli.Calls[^1]);
        Assert.Equal(["de-DE"], steps.Reports);
        await client.WriteWhatsNewAsync(1, "en-US", "• Faster sync\n• Fixes", ["de-DE"], Ct);
        Assert.Equal(["--json", "metadata", "whats-new", "1", "--from", "en-US", "--stdin", "--locales", "de-DE"], cli.Calls[^1]);
        Assert.Equal("• Faster sync\n• Fixes", cli.Inputs[^1]);
    }

    [Fact]
    public async Task ProposalsAreShownAndOneIsUsedAsTheDraft()
    {
        MetadataFields? used = null;
        var vm = new WriteViewModel(new AsoClient(Cli()), Acme, "en-US", f => { used = f; return Task.CompletedTask; });
        Assert.Equal("Acme Notes", vm.Brand);
        await vm.GenerateCommand.ExecuteAsync(null);
        Assert.Equal(2, vm.Proposals.Count);
        var card = vm.Proposals[0];
        Assert.Equal("Proposal A · rules 90/100 · 104/160 indexed characters", card.Header);
        Assert.Equal("Covers 2 of 2 priority phrases.", card.Coverage);
        Assert.True(card.HasPromotionalText);
        Assert.StartsWith("Repaired: Dropped from keywords", card.Repairs, StringComparison.Ordinal);
        Assert.Equal(2, card.Findings.Count);
        Assert.Equal("2 proposal(s) from the US market's evidence · cost $0.0020.", vm.Outcome);

        await vm.UseCommand.ExecuteAsync(card);
        Assert.True(vm.Used);
        Assert.Equal("Diary, memos, planner", used!.Subtitle);
    }

    [Fact]
    public async Task MakeBetterNeedsTheKeyAndCanBeUndone()
    {
        var cli = Cli();
        var status = new StatusViewModel();
        var vm = new MetadataViewModel(new AsoClient(cli), status) { SaveDelay = TimeSpan.Zero, App = Acme };
        await vm.LoadLocalesAsync();
        vm.SelectedLocale = vm.Locales.First(l => l.Locale == "en-US");
        await vm.ReloadAsync();

        Assert.False(vm.ImproveCommand.CanExecute(null));
        Assert.Contains("Settings → Connections", vm.WriterHint, StringComparison.Ordinal);
        vm.WriterConnected = true;
        Assert.True(vm.ImproveCommand.CanExecute(null));
        Assert.False(vm.UndoImproveCommand.CanExecute(null));
        var before = vm.CurrentFields();
        await vm.ImproveCommand.ExecuteAsync(null);
        Assert.StartsWith("Made better: rules ", status.Message, StringComparison.Ordinal);
        Assert.Equal(before, vm.BeforeImprove);

        await vm.UndoImproveCommand.ExecuteAsync(null);
        Assert.Null(vm.BeforeImprove);
        Assert.Equal("metadata draft", FakeCli.Command(cli.Calls[^1]));
        Assert.Contains("\"subtitle\":\"" + before.Subtitle, cli.Inputs[^1], StringComparison.Ordinal);
    }

    [Fact]
    public async Task EveryLocaleIsWrittenAndFailuresAreListed()
    {
        var cli = Cli();
        var written = 0;
        IReadOnlyList<MetadataLocale> locales = [new("de-DE", "German", "DE", null, false, 0, 1), new("en-US", "English (U.S.)", "US", "manual", true, 2, 0)];
        var vm = new WriteAllViewModel(new AsoClient(cli), Acme, locales, () => { written++; return Task.CompletedTask; });
        Assert.Equal("de-DE · German · evidence from DE", vm.Locales[0].Label);
        Assert.StartsWith("About $0.03", vm.CostHint, StringComparison.Ordinal);
        vm.Locales[0].IsSelected = false;
        Assert.StartsWith("About $0.02", vm.CostHint, StringComparison.Ordinal);
        vm.Locales[0].IsSelected = true;

        await vm.WriteCommand.ExecuteAsync(null);
        Assert.Contains("de-DE,en-US", cli.Calls[^1]);
        Assert.Equal(["Failed: Network error: offline", "Acme Notes: Daily Journal"], vm.Results.Select(r => r.Title));
        Assert.Equal("90", vm.Results[1].Score);
        Assert.Equal("Saved 1 of 2 locale(s) as drafts. The others are listed with the reason.", vm.Outcome);
        Assert.Equal(1, written);
    }

    [Fact]
    public async Task ReleaseNotesAreTranslatedIntoTheChosenLocales()
    {
        var cli = Cli();
        IReadOnlyList<MetadataLocale> locales =
            [new("en-US", "English (U.S.)", "US", null, true, 0, 0), new("en-GB", "English (U.K.)", null, null, false, 0, 0), new("fr-FR", "French", null, null, false, 0, 0)];
        var vm = new WhatsNewViewModel(new AsoClient(cli), Acme, locales, "en-US", "Bug fixes.", () => Task.CompletedTask);
        Assert.Equal([false, true, true], vm.Targets.Select(t => t.IsSelected));
        Assert.Equal("10 / 4000 characters", vm.Counter);
        vm.SourceLocale = "fr-FR";
        Assert.Equal([true, true, false], vm.Targets.Select(t => t.IsSelected));
        vm.SourceLocale = "en-US";

        await vm.TranslateCommand.ExecuteAsync(null);
        Assert.Equal(["--json", "metadata", "whats-new", "1000001", "--from", "en-US", "--stdin", "--locales", "en-GB,fr-FR"], cli.Calls[^1]);
        Assert.Equal([null, "Bug fixes.", "Corrections."], vm.Targets.Select(t => t.Result));
        Assert.Equal("Release notes saved in en-US and 2 other locale(s).", vm.Outcome);

        vm.Source = " ";
        await vm.TranslateCommand.ExecuteAsync(null);
        Assert.Equal("Write the release notes first.", vm.Error);
    }
}
