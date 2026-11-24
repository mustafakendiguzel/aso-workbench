using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>
/// One text field of the listing with its counter. Counting happens here so it follows every keystroke; the checks that decide
/// what Apple accepts come from the engine.
/// </summary>
public sealed partial class MetadataFieldViewModel(string key, string title, int limit, bool isMultiline, bool onAppInfo) : ObservableObject
{
    /// <summary>The engine's name for the field: name, subtitle, keywords, promotionalText, description, whatsNew.</summary>
    public string Key { get; } = key;
    public string Title { get; } = title;
    public int Limit { get; } = limit;
    public bool IsMultiline { get; } = isMultiline;
    /// <summary>Name and subtitle live on the app; the rest on the version.</summary>
    public string Resource { get; } = onAppInfo ? "App Info" : "Version";
    public string Placeholder => Key == "keywords" ? "comma,separated,keywords" : "";
    public double MinHeight => Key == "description" ? 180 : IsMultiline ? 70 : 0;

    /// <summary>Called after every edit the user makes (not when the field is filled from the engine).</summary>
    public Action? Edited { get; set; }

    private bool filling;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Counter), nameof(IsOver), nameof(IsAmbiguous), nameof(Changed))]
    public partial string Text { get; set; } = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Counter), nameof(Changed))]
    public partial string? Baseline { get; set; }

    public int CodePoints => MetadataViewModel.CodePoints(Text);
    public int Bytes => Encoding.UTF8.GetByteCount(Text);

    /// <summary>Over the limit under every way of counting.</summary>
    public bool IsOver => CodePoints > Limit && Bytes > Limit;

    /// <summary>Within the limit in characters but not in bytes, or the reverse: Apple documents both.</summary>
    public bool IsAmbiguous => (CodePoints <= Limit) != (Bytes <= Limit);

    public bool Changed => Baseline is not null && Baseline != Text;

    public string Counter
    {
        get
        {
            var text = $"{CodePoints} / {Limit} characters";
            if (Bytes != CodePoints || Key == "keywords") text += $" · {Bytes} bytes";
            if (Key == "keywords") text += $" · {MetadataViewModel.KeywordList(Text).Count} keywords";
            if (Changed) text += " · changed";
            return text;
        }
    }

    /// <summary>Shows text from the engine without counting it as an edit.</summary>
    public void Fill(string text, string? baseline)
    {
        filling = true;
        Text = text;
        Baseline = baseline;
        filling = false;
    }

    partial void OnTextChanged(string value)
    {
        if (!filling) Edited?.Invoke();
    }
}

/// <summary>A locale in the picker; the ones worth writing carry where their draft stands.</summary>
public sealed partial class MetadataLocaleLine(string locale, string name) : ObservableObject
{
    public string Locale { get; } = locale;
    public string Name { get; } = name;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Label))]
    public partial MetadataLocale? Status { get; set; }

    public string Label
    {
        get
        {
            var text = $"{Locale} · {Name}";
            if (Status is not { } s) return text;
            if (s.Baseline is { } b) text += b == "asc" ? " · App Store Connect" : " · manual baseline";
            if (s.HasDraft) text += " · draft";
            if (s.Changes > 0) text += $" · {s.Changes} changed";
            if (s.Errors > 0) text += $" · {s.Errors} error(s)";
            return text;
        }
    }
}

/// <summary>A rule finding or a validation issue, as the side panel lists them.</summary>
public sealed record MetadataNote(string Kind, string Text)
{
    public bool IsError => Kind == "error";
    public bool IsWarning => Kind == "warning";
}

/// <summary>One field that differs from the baseline; keywords as added, removed and kept.</summary>
public sealed record MetadataChangeLine(string Title, string Before, string After, KeywordChange? Keywords)
{
    public bool IsKeywords => Keywords is not null;
    public string Added => Keywords is { Added.Count: > 0 } k ? "+ " + string.Join(", ", k.Added) : "";
    public string Removed => Keywords is { Removed.Count: > 0 } k ? "− " + string.Join(", ", k.Removed) : "";
    public string Kept => Keywords is { } k ? $"{k.Kept.Count} kept" : "";
    public string BeforeText => Before.Length == 0 ? "(empty)" : Before;
    public string AfterText => After.Length == 0 ? "(empty)" : After;
}

/// <summary>
/// The macOS app's Metadata editor without App Store Connect: a draft per locale saved as you type, its counters, the ASO rules
/// and validation from the engine, the changes against the baseline, and the legal footer. Nothing reaches Apple from here.
/// </summary>
public sealed partial class MetadataViewModel : ObservableObject
{
    private readonly AsoClient client;
    private readonly StatusViewModel status;
    private IReadOnlyList<LocaleInfo>? allLocales;
    // Each edit starts a new wait; only the newest one saves, and a save or a switch ends every wait.
    private int saveGeneration;
    private bool dirty;

    public MetadataViewModel(AsoClient client, StatusViewModel status)
    {
        this.client = client;
        this.status = status;
        Fields =
        [
            new("name", "Name", 30, false, true),
            new("subtitle", "Subtitle", 30, false, true),
            new("keywords", "Keywords", 100, false, false),
            new("promotionalText", "Promotional Text", 170, true, false),
            new("description", "Description", 4000, true, false),
            new("whatsNew", "What's New", 4000, true, false),
        ];
        foreach (var field in Fields) field.Edited = Edited;
    }

    public IReadOnlyList<MetadataFieldViewModel> Fields { get; }
    public ObservableCollection<MetadataLocaleLine> Locales { get; } = [];
    public ObservableCollection<MetadataNote> Notes { get; } = [];
    public ObservableCollection<MetadataChangeLine> ChangeLines { get; } = [];

    /// <summary>How long typing pauses before the draft is saved.</summary>
    public TimeSpan SaveDelay { get; set; } = TimeSpan.FromMilliseconds(700);

    [ObservableProperty] public partial AppRecord? App { get; set; }

    [ObservableProperty] public partial MetadataLocaleLine? SelectedLocale { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasReport), nameof(HasBaseline), nameof(BaselineText), nameof(DraftText), nameof(RulesHeadline),
                              nameof(ScoreIsGood), nameof(ScoreIsFair), nameof(ScoreIsPoor), nameof(IndexedWords), nameof(FollowsEveryRule),
                              nameof(ChangesText), nameof(LegalStatus), nameof(LegalPresent))]
    [NotifyCanExecuteChangedFor(nameof(ResetToBaselineCommand), nameof(SetBaselineCommand), nameof(SaveLegalCommand),
                                nameof(InsertFooterHereCommand), nameof(InsertFooterEverywhereCommand), nameof(FillWhatsNewCommand))]
    public partial MetadataReport? Report { get; set; }

    [ObservableProperty] public partial bool LegalEnabled { get; set; } = true;
    [ObservableProperty] public partial string EulaUrl { get; set; } = "";
    [ObservableProperty] public partial string PrivacyUrl { get; set; } = "";
    [ObservableProperty] public partial string LegalNote { get; set; } = "";
    [ObservableProperty] public partial bool ShowLegalDetails { get; set; }

    public bool HasReport => Report is not null;
    public bool HasBaseline => Report?.Baseline is not null;

    public string BaselineText => Report is not { } r ? ""
        : r.Baseline is { } b
            ? (b.Source == "asc" ? "From App Store Connect" : "Entered manually")
              + (b.VersionString is { } v ? $" · version {v}" + (b.VersionState is { } s ? $" ({s})" : "") : "")
              + $" · {b.FetchedAt.ToLocalTime().ToString("g", CultureInfo.CurrentCulture)}"
            : $"No baseline for {r.Locale}. Enter what is live on the App Store today with Set baseline to see what your draft changes.";

    public string DraftText => Report?.DraftUpdatedAt is { } at
        ? $"Draft saved {at.ToLocalTime().ToString("g", CultureInfo.CurrentCulture)}. Drafts stay on this computer; nothing reaches Apple from here."
        : "No draft yet: the fields show the baseline. Edits are saved as you type.";

    public string RulesHeadline => Report is { } r ? $"{r.Rules.Score}/100 · {r.Rules.CharactersUsed}/160 indexed characters" : "";
    public bool ScoreIsGood => Report?.Rules.Score >= 85;
    public bool ScoreIsFair => Report?.Rules.Score is >= 60 and < 85;
    public bool ScoreIsPoor => Report?.Rules.Score < 60;
    public string IndexedWords => Report is { Rules.IndexedWords.Count: > 0 } r ? "Indexed words: " + string.Join(", ", r.Rules.IndexedWords) : "";
    public bool FollowsEveryRule => Report is not null && Notes.All(n => n.Kind == "info");

    public string ChangesText => Report is not { } r ? ""
        : r.Baseline is null ? "—"
        : r.Changes.Count == 0 ? "The draft equals the baseline." : $"{r.Changes.Count} field(s) differ from the baseline.";

    public bool LegalPresent => Report?.Legal is { Settings.Enabled: true, InDescription: true };

    public string LegalStatus => Report?.Legal is not { } legal ? ""
        : !legal.Settings.Enabled ? "Off"
        : legal.InDescription ? "Terms and privacy links are in this description."
        : "Not in this description yet: Insert here, or into every locale.";

    /// <summary>Characters as the App Store counts them (Unicode code points, not UTF-16 units).</summary>
    public static int CodePoints(string text) => text.EnumerateRunes().Count();

    /// <summary>The comma-separated keyword field as the engine splits it: trimmed, empties dropped.</summary>
    public static IReadOnlyList<string> KeywordList(string text) =>
        text.Split(',').Select(k => k.Trim()).Where(k => k.Length > 0).ToList();

    public MetadataFields CurrentFields() => new(Text("name"), Text("subtitle"), Text("keywords"), Text("promotionalText"), Text("description"),
                                                 Text("whatsNew"));

    private string Text(string key) => Fields.First(f => f.Key == key).Text;

    partial void OnAppChanged(AppRecord? oldValue, AppRecord? newValue)
    {
        if (oldValue?.TrackId == newValue?.TrackId) return;
        CancelPendingSave();
        dirty = false;
        Locales.Clear();
        Show(null, fields: true);
        if (newValue is not null) _ = status.QuietlyAsync(LoadLocalesAsync);
    }

    partial void OnSelectedLocaleChanged(MetadataLocaleLine? oldValue, MetadataLocaleLine? newValue)
    {
        if (oldValue?.Locale == newValue?.Locale) return;
        _ = status.QuietlyAsync(async () =>
        {
            if (oldValue is not null) await FlushAsync(oldValue).ConfigureAwait(true);
            Show(null, fields: true);
            await ReloadAsync().ConfigureAwait(true);
        });
    }

    /// <summary>The locales worth writing first (tracked markets' languages, then ones with a baseline or a draft), then every other one.</summary>
    public async Task LoadLocalesAsync()
    {
        if (App is not { } app) return;
        allLocales ??= await client.AllLocalesAsync().ConfigureAwait(true);
        var worth = await client.MetadataLocalesAsync(app.TrackId).ConfigureAwait(true);
        if (App?.TrackId != app.TrackId) return;
        var keep = SelectedLocale?.Locale;
        Locales.Clear();
        foreach (var l in worth) Locales.Add(new MetadataLocaleLine(l.Locale, l.Name) { Status = l });
        foreach (var l in allLocales.Where(l => worth.All(w => w.Locale != l.Id))) Locales.Add(new MetadataLocaleLine(l.Id, l.Name));
        SelectedLocale = Locales.FirstOrDefault(l => l.Locale == keep) ?? Locales.FirstOrDefault();
    }

    /// <summary>Reads the selected locale's draft and checks into the editor.</summary>
    public async Task ReloadAsync()
    {
        if (App is not { } app || SelectedLocale is not { } line) return;
        var report = await client.MetadataAsync(app.TrackId, line.Locale).ConfigureAwait(true);
        if (App?.TrackId == app.TrackId && SelectedLocale?.Locale == line.Locale && !dirty) Show(report, fields: true);
    }

    private void Edited()
    {
        if (App is null || SelectedLocale is null) return;
        dirty = true;
        var generation = ++saveGeneration;
        _ = status.QuietlyAsync(async () =>
        {
            if (SaveDelay > TimeSpan.Zero) await Task.Delay(SaveDelay).ConfigureAwait(true);
            if (generation == saveGeneration) await FlushAsync().ConfigureAwait(true);
        });
    }

    /// <summary>Saves the draft now when it has unsaved edits.</summary>
    public Task FlushAsync() => SelectedLocale is { } line ? FlushAsync(line) : Task.CompletedTask;

    private async Task FlushAsync(MetadataLocaleLine line)
    {
        if (!dirty || App is not { } app) return;
        CancelPendingSave();
        dirty = false;
        var fields = CurrentFields();
        var report = await client.SaveDraftAsync(app.TrackId, line.Locale, fields).ConfigureAwait(true);
        line.Status = Summary(report);
        // Typing may have gone on while saving: keep the editor's text, take everything else.
        if (App?.TrackId == app.TrackId && SelectedLocale?.Locale == line.Locale) Show(report, fields: false);
    }

    private void CancelPendingSave() => saveGeneration++;

    private bool CanReset() => Report is { Baseline: not null, Changes.Count: > 0 };

    [RelayCommand(CanExecute = nameof(CanReset))]
    private Task ResetToBaselineAsync() => Act("Resetting the draft…", async (app, line) =>
    {
        dirty = false;
        CancelPendingSave();
        var report = await client.ResetDraftAsync(app.TrackId, line.Locale).ConfigureAwait(true);
        line.Status = Summary(report);
        Show(report, fields: true);
        status.Info($"The {line.Locale} draft is the baseline again.");
    });

    private bool CanEdit() => Report is not null;

    /// <summary>An editor for the baseline of the selected locale, filled with the current one.</summary>
    public MetadataFieldViewModel[] CreateBaselineFields()
    {
        var current = Report?.Baseline?.Fields ?? MetadataFields.Empty;
        MetadataFieldViewModel[] fields =
        [
            new("name", "Name", 30, false, true), new("subtitle", "Subtitle", 30, false, true), new("keywords", "Keywords", 100, false, false),
            new("promotionalText", "Promotional Text", 170, true, false), new("description", "Description", 4000, true, false),
            new("whatsNew", "What's New", 4000, true, false),
        ];
        foreach (var f in fields) f.Fill(Value(current, f.Key), null);
        return fields;
    }

    /// <summary>Stores what the baseline editor holds as the locale's baseline.</summary>
    [RelayCommand(CanExecute = nameof(CanEdit))]
    private Task SetBaselineAsync(IReadOnlyList<MetadataFieldViewModel>? fields) => fields is null ? Task.CompletedTask
        : Act("Saving the baseline…", async (app, line) =>
        {
            await FlushAsync(line).ConfigureAwait(true);
            string V(string key) => fields.First(f => f.Key == key).Text;
            var baseline = new MetadataFields(V("name"), V("subtitle"), V("keywords"), V("promotionalText"), V("description"), V("whatsNew"));
            var report = await client.SetBaselineAsync(app.TrackId, line.Locale, baseline).ConfigureAwait(true);
            line.Status = Summary(report);
            Show(report, fields: true);
            status.Info($"Baseline for {line.Locale} saved: {report.Changes.Count} field(s) of the draft differ from it.");
        });

    [RelayCommand(CanExecute = nameof(CanEdit))]
    private Task SaveLegalAsync() => Act("Saving the legal footer…", async (app, _) =>
    {
        var settings = await client.SetLegalFooterAsync(app.TrackId, new LegalFooterSettings(LegalEnabled, EulaUrl, PrivacyUrl, LegalNote))
            .ConfigureAwait(true);
        await FlushAsync().ConfigureAwait(true);
        await ReloadAsync().ConfigureAwait(true);
        status.Info(settings.Enabled ? "Legal footer saved. Insert it here or into every locale." : "Legal footer turned off.");
    });

    [RelayCommand(CanExecute = nameof(CanEdit))]
    private Task InsertFooterHereAsync() => Act("Inserting the legal footer…", async (app, line) =>
    {
        await FlushAsync(line).ConfigureAwait(true);
        var batch = await client.InsertLegalFooterAsync(app.TrackId, line.Locale).ConfigureAwait(true);
        await ReloadAsync().ConfigureAwait(true);
        status.Info(batch.Changed.Count == 0 ? "This description already ends with the legal footer." : "Legal footer added to this description.");
    });

    [RelayCommand(CanExecute = nameof(CanEdit))]
    private Task InsertFooterEverywhereAsync() => Act("Inserting the legal footer…", async (app, line) =>
    {
        await FlushAsync(line).ConfigureAwait(true);
        var batch = await client.InsertLegalFooterAsync(app.TrackId, null).ConfigureAwait(true);
        await LoadLocalesAsync().ConfigureAwait(true);
        await ReloadAsync().ConfigureAwait(true);
        status.Info($"Legal footer added to {batch.Changed.Count} of {batch.Locales} locale(s); the rest already had it.");
    });

    [RelayCommand(CanExecute = nameof(CanEdit))]
    private Task FillWhatsNewAsync() => Act("Filling empty release notes…", async (app, line) =>
    {
        await FlushAsync(line).ConfigureAwait(true);
        var batch = await client.FillEmptyWhatsNewAsync(app.TrackId).ConfigureAwait(true);
        await LoadLocalesAsync().ConfigureAwait(true);
        await ReloadAsync().ConfigureAwait(true);
        status.Info($"What's New filled with the default note in {batch.Changed.Count} of {batch.Locales} locale(s); the others already had notes.");
    });

    private Task Act(string message, Func<AppRecord, MetadataLocaleLine, Task> work) =>
        App is { } app && SelectedLocale is { } line ? status.RunAsync(message, () => work(app, line)) : Task.CompletedTask;

    private static MetadataLocale Summary(MetadataReport r) =>
        new(r.Locale, r.Name, r.Market, r.Baseline?.Source, r.DraftUpdatedAt is not null, r.Changes.Count,
            r.Issues.Count(i => i.Severity == ValidationSeverity.Error));

    private static string Value(MetadataFields f, string key) => key switch
    {
        "name" => f.Name,
        "subtitle" => f.Subtitle,
        "keywords" => f.Keywords,
        "promotionalText" => f.PromotionalText,
        "description" => f.Description,
        _ => f.WhatsNew,
    };

    private void Show(MetadataReport? report, bool fields)
    {
        foreach (var f in Fields)
        {
            var baseline = report?.Baseline is { } b ? Value(b.Fields, f.Key) : null;
            if (fields) f.Fill(report is null ? "" : Value(report.Draft, f.Key), baseline);
            else f.Baseline = baseline;
        }
        Notes.Clear();
        ChangeLines.Clear();
        if (report is not null)
        {
            foreach (var finding in report.Rules.Findings) Notes.Add(new MetadataNote(finding.Kind, finding.Message));
            foreach (var issue in report.Issues.OrderByDescending(i => i.Severity))
                Notes.Add(new MetadataNote(issue.Severity.ToString().ToLowerInvariant(), $"{TitleOf(issue.Field)}: {issue.Message}"));
            foreach (var c in report.Changes)
                ChangeLines.Add(new MetadataChangeLine(TitleOf(c.Field), c.Before, c.After, c.Field == "keywords" ? report.KeywordChange : null));
            // A background draft save leaves the footer settings being typed alone.
            if (fields)
            {
                var legal = report.Legal.Settings;
                (LegalEnabled, EulaUrl, PrivacyUrl, LegalNote) = (legal.Enabled, legal.EulaUrl, legal.PrivacyUrl, legal.Note);
            }
        }
        Report = report;
    }

    private string TitleOf(string key) => Fields.FirstOrDefault(f => f.Key == key)?.Title ?? key;
}
