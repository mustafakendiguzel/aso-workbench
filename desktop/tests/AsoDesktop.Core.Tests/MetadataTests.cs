using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class MetadataTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    // The fixtures are the real engine's answers for Keynote tracked in the US and Germany, with a typed-in en-US baseline and a
    // draft whose subtitle is one character too long.
    private static readonly AppRecord Keynote = new(361285480, "com.apple.Keynote", "Keynote", "Apple", null, null, null, DateTimeOffset.UnixEpoch);

    private static (MetadataViewModel Vm, FakeCli Cli, StatusViewModel Status) Make()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Command(args) switch
        {
            "locales" => FakeCli.Fixture("locales"),
            "metadata locales" => FakeCli.Fixture("metadata-locales"),
            "metadata show" or "metadata draft" or "metadata reset" or "metadata baseline" =>
                FakeCli.Fixture(args.Contains("en-US") ? "metadata-show" : "metadata-show-new"),
            "metadata legal" => FakeCli.Ok("""{"enabled":true,"eulaURL":"","privacyURL":"https://example.com/privacy","note":""}"""),
            "metadata footer" or "metadata fill-whats-new" => FakeCli.Ok("""{"changed":["en-US"],"locales":2}"""),
            _ => FakeCli.Ok("{}"),
        };
        var status = new StatusViewModel();
        return (new MetadataViewModel(new AsoClient(cli), status) { SaveDelay = TimeSpan.Zero }, cli, status);
    }

    private static MetadataViewModel Selecting(MetadataViewModel vm, string locale)
    {
        vm.SelectedLocale = vm.Locales.First(l => l.Locale == locale);
        return vm;
    }

    private static int CallsTo(FakeCli cli, string command) => cli.Calls.Count(c => FakeCli.Command(c) == command);

    [Fact]
    public async Task ReportsLocalesAndTheLanguageListAreRead()
    {
        var client = new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("metadata-show") });
        var report = await client.MetadataAsync(361285480, "en-US", Ct);
        Assert.Equal(("manual", "Keynote"), (report.Baseline!.Source, report.Baseline.Fields.Name));
        Assert.Equal(["subtitle", "keywords"], report.Changes.Select(c => c.Field));
        Assert.Equal(["speaker", "charts"], report.KeywordChange!.Added);
        Assert.Equal((61, 64), (report.Rules.Score, report.Rules.CharactersUsed));
        Assert.Equal(ValidationSeverity.Error, report.Issues[0].Severity);
        Assert.Equal("https://example.com/privacy", report.Legal.Settings.PrivacyUrl);
        Assert.StartsWith("https://www.apple.com/legal/", report.Legal.EffectiveEula, StringComparison.Ordinal);
        Assert.NotNull(report.DraftUpdatedAt);

        var fresh = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("metadata-show-new") }).MetadataAsync(1, "de-DE", Ct);
        Assert.Null(fresh.Baseline);
        Assert.Null(fresh.DraftUpdatedAt);
        Assert.Equal(MetadataFields.Empty, fresh.Draft);

        var locales = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("metadata-locales") }).MetadataLocalesAsync(1, Ct);
        Assert.Equal([("de-DE", null, 1), ("en-US", "manual", 1)], locales.Select(l => (l.Locale, l.Baseline, l.Errors)));
        var all = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("locales") }).AllLocalesAsync(Ct);
        Assert.Contains(all, l => l.Id == "tr" || l.Id == "tr-TR");
    }

    [Fact]
    public async Task DraftsTravelAsJsonThroughStdin()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("metadata-show") };
        var fields = new MetadataFields("Keynote", "Slides", "deck", "", "Line one\nLine two", "");
        await new AsoClient(cli).SaveDraftAsync(361285480, "en-US", fields, Ct);
        Assert.Equal(["--json", "metadata", "draft", "361285480", "--locale", "en-US", "--stdin"], cli.Calls[0]);
        Assert.Equal("""{"name":"Keynote","subtitle":"Slides","keywords":"deck","promotionalText":"","description":"Line one\nLine two","whatsNew":""}""",
                     cli.Inputs[0]);

        await new AsoClient(cli).SetLegalFooterAsync(1, new LegalFooterSettings(false, "", "https://example.com/privacy", ""), Ct);
        Assert.Equal(["--json", "metadata", "legal", "1", "--off", "--eula", "", "--privacy", "https://example.com/privacy", "--note", ""], cli.Calls[1]);
    }

    [Fact]
    public void TheEditorShowsTheLocalesWorthWritingFirstAndTheSelectedDraft()
    {
        var (vm, cli, _) = Make();
        vm.App = Keynote;

        Assert.Equal("de-DE · German · 1 error(s)", vm.Locales[0].Label);
        Assert.Equal("en-US · English (U.S.) · manual baseline · draft · 2 changed · 1 error(s)", vm.Locales[1].Label);
        Assert.True(vm.Locales.Count > 30);
        Assert.Null(vm.Locales[2].Status);
        Assert.Equal("de-DE", vm.SelectedLocale?.Locale);
        Assert.False(vm.ResetToBaselineCommand.CanExecute(null));

        Selecting(vm, "en-US");
        var subtitle = vm.Fields[1];
        Assert.Equal("Design Presentations and Slides", subtitle.Text);
        Assert.True(subtitle.IsOver);
        Assert.Equal("31 / 30 characters · changed", subtitle.Counter);
        Assert.Equal("26 / 100 characters · 26 bytes · 4 keywords · changed", vm.Fields[2].Counter);
        Assert.Equal("61/100 · 64/160 indexed characters", vm.RulesHeadline);
        Assert.True(vm.ScoreIsFair);
        Assert.True(vm.Notes[0].IsError);
        Assert.Contains(vm.Notes, n => n.Text == "Subtitle: Subtitle is 31 characters / 31 bytes; the limit is 30.");
        Assert.False(vm.FollowsEveryRule);
        Assert.Equal(["Subtitle", "Keywords"], vm.ChangeLines.Select(c => c.Title));
        Assert.Equal(("+ speaker, charts", "− presentation, pitch", "2 kept"), (vm.ChangeLines[1].Added, vm.ChangeLines[1].Removed, vm.ChangeLines[1].Kept));
        Assert.StartsWith("Entered manually · ", vm.BaselineText, StringComparison.Ordinal);
        Assert.StartsWith("Not in this description yet", vm.LegalStatus, StringComparison.Ordinal);
        Assert.Equal("https://example.com/privacy", vm.PrivacyUrl);
        Assert.True(vm.ResetToBaselineCommand.CanExecute(null));
        // Filling the editor from the engine is not an edit.
        Assert.Equal(0, CallsTo(cli, "metadata draft"));
    }

    [Fact]
    public async Task EditsAreSavedAndKeptWhileTheReportRefreshes()
    {
        var (vm, cli, _) = Make();
        vm.App = Keynote;
        Selecting(vm, "en-US");
        vm.Fields[0].Text = "Keynote Pro";
        await vm.FlushAsync();

        Assert.Equal(1, CallsTo(cli, "metadata draft"));
        Assert.Contains("\"name\":\"Keynote Pro\"", cli.Inputs[cli.Calls.FindIndex(c => FakeCli.Command(c) == "metadata draft")], StringComparison.Ordinal);
        Assert.Equal("Keynote Pro", vm.Fields[0].Text);   // the engine's answer still holds the old name
        Assert.Equal("Keynote", vm.Fields[0].Baseline);
    }

    [Fact]
    public void SwitchingLocalesSavesTheEditsFirst()
    {
        var (vm, cli, _) = Make();
        vm.SaveDelay = TimeSpan.FromHours(1);
        vm.App = Keynote;
        Selecting(vm, "en-US");
        vm.Fields[2].Text = "slides,deck";
        Assert.Equal(0, CallsTo(cli, "metadata draft"));

        Selecting(vm, "de-DE");
        var draft = cli.Calls.Single(c => FakeCli.Command(c) == "metadata draft");
        Assert.Contains("en-US", draft);
        Assert.Equal("", vm.Fields[2].Text);
    }

    [Fact]
    public async Task BaselineFooterAndReleaseNotesGoToTheEngine()
    {
        var (vm, cli, status) = Make();
        vm.App = Keynote;
        Selecting(vm, "en-US");

        var baseline = vm.CreateBaselineFields();
        Assert.Equal("Keynote", baseline[0].Text);
        baseline[1].Text = "Design Presentations";
        await vm.SetBaselineCommand.ExecuteAsync(baseline);
        Assert.Contains("\"subtitle\":\"Design Presentations\"", cli.Inputs[cli.Calls.FindIndex(c => FakeCli.Command(c) == "metadata baseline")],
                        StringComparison.Ordinal);

        vm.LegalNote = "Renews monthly.";
        await vm.SaveLegalCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "metadata", "legal", "361285480", "--on", "--eula", "", "--privacy",
                                                          "https://example.com/privacy", "--note", "Renews monthly."]));

        await vm.InsertFooterHereCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "metadata", "footer", "361285480", "--locale", "en-US"]));
        await vm.InsertFooterEverywhereCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "metadata", "footer", "361285480"]));
        Assert.Equal("Legal footer added to 1 of 2 locale(s); the rest already had it.", status.Message);

        await vm.FillWhatsNewCommand.ExecuteAsync(null);
        Assert.Equal("What's New filled with the default note in 1 of 2 locale(s); the others already had notes.", status.Message);
        await vm.ResetToBaselineCommand.ExecuteAsync(null);
        Assert.Contains(cli.Calls, c => c.SequenceEqual(["--json", "metadata", "reset", "361285480", "--locale", "en-US"]));
    }

    [Fact]
    public void CountersFollowTheAppStore()
    {
        Assert.Equal(5, MetadataViewModel.CodePoints("Notes"));
        Assert.Equal(4, MetadataViewModel.CodePoints("Bütç"));
        Assert.Equal(2, MetadataViewModel.CodePoints("😀😀"));   // four UTF-16 units, two characters
        Assert.Equal(["a", "b c"], MetadataViewModel.KeywordList(" a,, b c ,"));

        var field = new MetadataFieldViewModel("subtitle", "Subtitle", 30, false, true);
        field.Fill(new string('ü', 20), null);   // 20 characters, 40 bytes: within one count, over the other
        Assert.True(field.IsAmbiguous);
        Assert.False(field.IsOver);
        Assert.Equal("20 / 30 characters · 40 bytes", field.Counter);
    }
}
