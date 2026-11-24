using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>One proposal as the writer's dialog shows it.</summary>
public sealed record ProposalCard(WrittenProposal Proposal)
{
    public string Header => $"Proposal {Proposal.Label} · rules {Proposal.Score}/100 · {Proposal.CharactersUsed}/160 indexed characters";
    public string Coverage => Proposal.Covered.Count + Proposal.Missed.Count == 0 ? "No priority phrases for this market yet."
        : $"Covers {Proposal.Covered.Count} of {Proposal.Covered.Count + Proposal.Missed.Count} priority phrases"
          + (Proposal.Missed.Count > 0 ? "; misses " + string.Join(", ", Proposal.Missed) : ".");
    public string Title => Proposal.Fields.Name;
    public string Subtitle => Proposal.Fields.Subtitle;
    public string Keywords => Proposal.Fields.Keywords;
    public string PromotionalText => Proposal.Fields.PromotionalText;
    public bool HasPromotionalText => Proposal.Fields.PromotionalText.Length > 0;
    public string Rationale => Proposal.Rationale;
    public string Repairs => Proposal.Repairs.Count == 0 ? "" : "Repaired: " + string.Join(" ", Proposal.Repairs);
    public IReadOnlyList<MetadataNote> Findings { get; } =
        Proposal.Findings.Take(5).Select(f => new MetadataNote(f.Kind, f.Message))
            .Concat(Proposal.Issues.Select(i => new MetadataNote(i.Severity.ToString().ToLowerInvariant(), $"{MetadataViewModel.FieldTitle(i.Field)}: {i.Message}")))
            .ToList();
}

/// <summary>The shared inputs of the writer's dialogs: the brand strategy, the brand and the notes for the model.</summary>
public abstract partial class WriterInputs(AsoClient client, AppRecord app) : ObservableObject
{
    protected AsoClient Client { get; } = client;
    protected AppRecord App { get; } = app;

    /// <summary>Brand first, then feature words (demand comes from the brand); otherwise feature words first.</summary>
    [ObservableProperty] public partial bool BrandFirst { get; set; }

    /// <summary>The name up to the first colon, as the macOS writer takes it.</summary>
    [ObservableProperty] public partial string Brand { get; set; } = app.Name.Split(':')[0].Trim();

    [ObservableProperty] public partial string Notes { get; set; } = "";

    [ObservableProperty] public partial bool IsBusy { get; set; }
    [ObservableProperty] public partial string? Error { get; set; }
    [ObservableProperty] public partial string? Outcome { get; set; }

    protected string? BrandOption => string.IsNullOrWhiteSpace(Brand) ? null : Brand.Trim();
    protected string? NotesOption => string.IsNullOrWhiteSpace(Notes) ? null : Notes.Trim();

    protected async Task Busy(Func<Task> work)
    {
        IsBusy = true;
        Error = null;
        try
        {
            await work().ConfigureAwait(true);
        }
        catch (AsoCliException e)
        {
            Error = e.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }
}

/// <summary>
/// Write this locale with AI, as the macOS Assistant sheet: three proposals from the market's evidence, each repaired and scored by the
/// engine; Use this saves one as the draft.
/// </summary>
public sealed partial class WriteViewModel(AsoClient client, AppRecord app, string locale, Func<MetadataFields, Task> use) : WriterInputs(client, app)
{
    public string Locale { get; } = locale;
    public string Title => $"Write {Locale} with AI";
    public ObservableCollection<ProposalCard> Proposals { get; } = [];

    /// <summary>Rewrite the promotional text and description too, even when the draft has them.</summary>
    [ObservableProperty] public partial bool RewriteCopy { get; set; }

    [ObservableProperty] public partial bool Used { get; set; }

    [RelayCommand]
    private Task GenerateAsync() => Busy(async () =>
    {
        Proposals.Clear();
        var result = await Client.WriteAsync(App.TrackId, Locale, BrandFirst, BrandOption, NotesOption, RewriteCopy).ConfigureAwait(true);
        foreach (var p in result.Proposals) Proposals.Add(new ProposalCard(p));
        Outcome = result.Proposals.Count == 0 ? "The model gave no usable proposal; try again."
            : $"{result.Proposals.Count} proposal(s) from the {result.Market ?? "untracked"} market's evidence" + (result.Cost is { } c ? $" · cost {c}." : ".");
    });

    /// <summary>Saves the proposal as the locale's draft.</summary>
    [RelayCommand]
    private Task UseAsync(ProposalCard? card) => card is null ? Task.CompletedTask : Busy(async () =>
    {
        await use(card.Proposal.Fields).ConfigureAwait(true);
        Used = true;
    });
}

/// <summary>A locale offered to Write all locales.</summary>
public sealed partial class BatchLocaleLine(MetadataLocale locale) : ObservableObject
{
    public string Locale => Status.Locale;
    public MetadataLocale Status { get; } = locale;
    public string Label => $"{Status.Locale} · {Status.Name}" + (Status.Market is { } m ? $" · evidence from {m}" : " · no tracked market");

    [ObservableProperty] public partial bool IsSelected { get; set; } = true;
}

/// <summary>One locale's result of Write all locales.</summary>
public sealed record BatchResultLine(BatchWrite Write)
{
    public string Locale => Write.Locale;
    public string Market => Write.Market ?? "";
    public string Score => Write.Proposal?.Score.ToString(CultureInfo.CurrentCulture) ?? "";
    public string Covers => Write.Proposal is { } p ? $"{p.Covered.Count}/{p.Covered.Count + p.Missed.Count}" : "";
    public string Title => Write.Proposal?.Fields.Name ?? "Failed: " + (Write.Error ?? "");
    public string Subtitle => Write.Proposal?.Fields.Subtitle ?? "";
    public string Keywords => Write.Proposal?.Fields.Keywords ?? "";
}

/// <summary>
/// Write all locales, as the macOS batch sheet: the chosen locales one after another (market languages first), each one's best proposal
/// saved as its draft.
/// </summary>
public sealed partial class WriteAllViewModel : WriterInputs
{
    private readonly Func<Task> written;

    public WriteAllViewModel(AsoClient client, AppRecord app, IEnumerable<MetadataLocale> locales, Func<Task> written) : base(client, app)
    {
        this.written = written;
        foreach (var l in locales)
        {
            var line = new BatchLocaleLine(l);
            line.PropertyChanged += (_, _) => OnPropertyChanged(nameof(CostHint));
            Locales.Add(line);
        }
    }

    public ObservableCollection<BatchLocaleLine> Locales { get; } = [];
    public ObservableCollection<BatchResultLine> Results { get; } = [];

    /// <summary>The locale being written.</summary>
    [ObservableProperty] public partial string? Step { get; set; }

    /// <summary>About two cents per locale with the default model, as the macOS app estimates it.</summary>
    public string CostHint => "About $" + (Locales.Count(l => l.IsSelected) * 0.016).ToString("0.00", CultureInfo.InvariantCulture)
                              + " with the default model; each locale is one model request and a few small ones.";

    [RelayCommand]
    private Task WriteAsync() => Busy(async () =>
    {
        var chosen = Locales.Where(l => l.IsSelected).Select(l => l.Locale).ToList();
        if (chosen.Count == 0) { Error = "Choose at least one locale."; return; }
        Results.Clear();
        var progress = new Progress<string>(locale => Step = $"Writing {locale}…");
        var lines = await Client.WriteAllAsync(App.TrackId, chosen, BrandFirst, BrandOption, NotesOption, progress).ConfigureAwait(true);
        foreach (var line in lines) Results.Add(new BatchResultLine(line));
        Step = null;
        var saved = lines.Count(l => l.Proposal is not null);
        Outcome = $"Saved {saved} of {lines.Count} locale(s) as drafts." + (saved < lines.Count ? " The others are listed with the reason." : "");
        await written().ConfigureAwait(true);
    });
}

/// <summary>A target of What's New for all locales.</summary>
public sealed partial class WhatsNewTarget(string locale, string name) : ObservableObject
{
    public string Locale { get; } = locale;
    public string Label => $"{Locale} · {name}";

    [ObservableProperty] public partial bool IsSelected { get; set; } = true;

    [ObservableProperty] public partial string? Result { get; set; }
}

/// <summary>What's New for all locales: one source text, saved into its locale and translated into each chosen one.</summary>
public sealed partial class WhatsNewViewModel : WriterInputs
{
    private readonly Func<Task> written;

    public WhatsNewViewModel(AsoClient client, AppRecord app, IReadOnlyList<MetadataLocale> locales, string sourceLocale, string source,
                             Func<Task> written) : base(client, app)
    {
        this.written = written;
        SourceLocales = locales.Select(l => l.Locale).ToList();
        foreach (var l in locales) Targets.Add(new WhatsNewTarget(l.Locale, l.Name));
        SourceLocale = sourceLocale;
        OnSourceLocaleChanged(sourceLocale);
        Source = source;
    }

    public IReadOnlyList<string> SourceLocales { get; }
    public ObservableCollection<WhatsNewTarget> Targets { get; } = [];

    [ObservableProperty] public partial string SourceLocale { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Counter))]
    public partial string Source { get; set; }

    public string Counter => $"{MetadataViewModel.CodePoints(Source)} / 4000 characters";

    partial void OnSourceLocaleChanged(string value)
    {
        foreach (var t in Targets) t.IsSelected = t.Locale != value;
    }

    [RelayCommand]
    private Task TranslateAsync() => Busy(async () =>
    {
        var chosen = Targets.Where(t => t.IsSelected && t.Locale != SourceLocale).ToList();
        if (Source.Trim().Length == 0) { Error = "Write the release notes first."; return; }
        var lines = await Client.WriteWhatsNewAsync(App.TrackId, SourceLocale, Source, chosen.Select(t => t.Locale).ToList()).ConfigureAwait(true);
        foreach (var line in lines)
            if (Targets.FirstOrDefault(t => t.Locale == line.Locale) is { } target) target.Result = line.Text ?? "Failed: " + line.Error;
        var done = lines.Count(l => l.Text is not null);
        Outcome = $"Release notes saved in {SourceLocale} and {done} other locale(s)" + (done < lines.Count ? $"; {lines.Count - done} failed." : ".");
        await written().ConfigureAwait(true);
    });
}
