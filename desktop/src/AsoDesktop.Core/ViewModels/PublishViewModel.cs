using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>One locale in the publish dialog: what applying it would send, whether it goes, and what came back.</summary>
public sealed partial class PublishLocaleLine(PublishPlan plan) : ObservableObject
{
    public PublishPlan Plan { get; } = plan;

    public string Header => $"{Plan.Locale} · {Plan.Name} · " + (Plan.Exists ? "on App Store Connect" : "new language, created on App Store Connect");

    public bool IsReady => Plan.IsReady;

    public string Summary => Plan.Blocked is { } why ? why
        : $"{Plan.Changes.Count} field(s) will be sent." + (Plan.Automatic.Count > 0 ? " " + string.Join(" ", Plan.Automatic) : "");

    public IReadOnlyList<MetadataChangeLine> Changes { get; } =
        plan.Changes.Select(c => new MetadataChangeLine(MetadataViewModel.FieldTitle(c.Field), c.Before, c.After, null)).ToList();

    /// <summary>Only ready locales can be chosen; they start chosen.</summary>
    [ObservableProperty] public partial bool IsSelected { get; set; } = plan.IsReady;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasResult), nameof(ResultText), nameof(Succeeded), nameof(Failed))]
    public partial PublishResult? Result { get; set; }

    public bool HasResult => Result is not null;
    public bool Succeeded => Result?.Succeeded == true;
    public bool Failed => Result is { Succeeded: false };

    public string ResultText => Result switch
    {
        null => "",
        { Status: "applied" or "partial" } r => r.Message,
        { Status: "refused" } r => "Refused: " + r.Message,
        { } r => "Failed: " + r.Message,
    };

    partial void OnIsSelectedChanged(bool value)
    {
        if (value && !IsReady) IsSelected = false;
    }
}

/// <summary>
/// The confirm step before anything is written to App Store Connect, as the macOS app's Apply sheets: the editable version (or
/// creating the next one), each locale's changes read against what Apple holds now, why a locale would be refused, and copying
/// screenshots into languages that are created. Publishing writes, re-reads and logs every locale.
/// </summary>
public sealed partial class PublishViewModel : ObservableObject
{
    private readonly AsoClient client;
    private readonly AppRecord app;
    private readonly string? locale;
    private readonly Func<Task> published;
    private bool loading;

    /// <param name="locale">One locale, or null for every locale with a draft.</param>
    /// <param name="copySources">Locales on App Store Connect whose screenshots can be copied into a new one.</param>
    public PublishViewModel(AsoClient client, AppRecord app, string? locale, IReadOnlyList<string> copySources, Func<Task> published)
    {
        this.client = client;
        this.app = app;
        this.locale = locale;
        this.published = published;
        CopySources = [NoCopy, .. copySources];
        CopyScreenshotsFrom = NoCopy;
    }

    public const string NoCopy = "Do not copy screenshots";

    public bool IsAll => locale is null;

    public string Title => IsAll ? $"Publish every draft of {app.Name}" : $"Publish {locale} of {app.Name}";

    public ObservableCollection<PublishLocaleLine> Lines { get; } = [];
    public IReadOnlyList<string> CopySources { get; }

    [ObservableProperty] public partial string CopyScreenshotsFrom { get; set; }

    /// <summary>Create the locale on App Store Connect when it does not exist yet (always on when publishing every draft).</summary>
    [ObservableProperty] public partial bool CreateMissing { get; set; } = true;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(VersionText), nameof(NeedsVersion), nameof(EditableVersion))]
    [NotifyCanExecuteChangedFor(nameof(CreateVersionCommand))]
    public partial IReadOnlyList<AscVersion>? Versions { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(CreateVersionCommand))]
    public partial string NewVersion { get; set; } = "";

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PublishCommand), nameof(CreateVersionCommand))]
    public partial bool IsBusy { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PublishCommand))]
    public partial bool IsDone { get; set; }

    [ObservableProperty] public partial string? Error { get; set; }
    [ObservableProperty] public partial string? Outcome { get; set; }

    public AscVersion? EditableVersion => Versions?.FirstOrDefault(v => v.Editable);

    public bool NeedsVersion => Versions is not null && EditableVersion is null;

    public string VersionText => Versions is null ? "Reading App Store Connect…"
        : EditableVersion is { } v ? $"Version {v.Version} ({v.State}) takes the listing; the live version stays as it is."
        : Versions.Count == 0 ? "The app has no iOS version on App Store Connect yet. Create the first one below."
        : $"No version can be edited: {Versions[0].Version} is {Versions[0].State}. Create the next version to write the listing; upload its build from Xcode later.";

    public bool HasNewLocales => Lines.Any(l => !l.Plan.Exists);

    public bool CanChooseCreateMissing => !IsAll;

    public int SelectedCount => Lines.Count(l => l.IsSelected);

    /// <summary>Reads the versions and the plans; nothing is written.</summary>
    public async Task LoadAsync()
    {
        await Busy(async () =>
        {
            Versions = await client.AscVersionsAsync(app.TrackId).ConfigureAwait(true);
            await LoadPlansAsync().ConfigureAwait(true);
        }).ConfigureAwait(true);
    }

    private async Task LoadPlansAsync()
    {
        var copy = CopyScreenshotsFrom == NoCopy ? null : CopyScreenshotsFrom;
        IReadOnlyList<PublishPlan> plans = locale is { } one
            ? [await client.PublishPlanAsync(app.TrackId, one, CreateMissing, copy).ConfigureAwait(true)]
            : await client.PublishPlansAsync(app.TrackId, copy).ConfigureAwait(true);
        foreach (var line in Lines) line.PropertyChanged -= LineChanged;
        Lines.Clear();
        foreach (var plan in plans)
        {
            var line = new PublishLocaleLine(plan);
            line.PropertyChanged += LineChanged;
            Lines.Add(line);
        }
        OnPropertyChanged(nameof(HasNewLocales));
        OnPropertyChanged(nameof(SelectedCount));
        PublishCommand.NotifyCanExecuteChanged();
    }

    private void LineChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(PublishLocaleLine.IsSelected)) return;
        OnPropertyChanged(nameof(SelectedCount));
        PublishCommand.NotifyCanExecuteChanged();
    }

    partial void OnCreateMissingChanged(bool value) => Replan();

    partial void OnCopyScreenshotsFromChanged(string value) => Replan();

    private void Replan()
    {
        if (Versions is null || IsDone) return;
        _ = Busy(LoadPlansAsync);
    }

    private bool CanCreateVersion() => !IsBusy && NeedsVersion && NewVersion.Trim().Length > 0;

    /// <summary>Creates the next version on App Store Connect, then plans again against it.</summary>
    [RelayCommand(CanExecute = nameof(CanCreateVersion))]
    private Task CreateVersionAsync() => Busy(async () =>
    {
        var created = await client.CreateVersionAsync(app.TrackId, NewVersion.Trim()).ConfigureAwait(true);
        Outcome = $"Created version {created.Version} ({created.State}).";
        NewVersion = "";
        Versions = await client.AscVersionsAsync(app.TrackId).ConfigureAwait(true);
        await LoadPlansAsync().ConfigureAwait(true);
    });

    private bool CanPublish() => !IsBusy && !IsDone && Lines.Any(l => l.IsSelected && l.IsReady);

    /// <summary>Writes the chosen locales to App Store Connect; each is re-read and logged by the engine.</summary>
    [RelayCommand(CanExecute = nameof(CanPublish))]
    private Task PublishAsync() => Busy(async () =>
    {
        var chosen = Lines.Where(l => l.IsSelected && l.IsReady).ToList();
        var copy = CopyScreenshotsFrom == NoCopy ? null : CopyScreenshotsFrom;
        IReadOnlyList<PublishResult> results = locale is { } one
            ? [await client.PublishAsync(app.TrackId, one, CreateMissing, copy).ConfigureAwait(true)]
            : await client.PublishAllAsync(app.TrackId, chosen.Select(l => l.Plan.Locale).ToList(), copy).ConfigureAwait(true);
        foreach (var result in results)
            if (Lines.FirstOrDefault(l => l.Plan.Locale == result.Locale) is { } line) line.Result = result;
        var applied = results.Count(r => r.Succeeded);
        Outcome = applied == results.Count
            ? $"Published {applied} locale(s) to App Store Connect and read them back."
            : $"Published {applied} of {results.Count} locale(s); see each locale below.";
        IsDone = true;
        await published().ConfigureAwait(true);
    });

    private async Task Busy(Func<Task> work)
    {
        if (loading) return;
        loading = true;
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
            loading = false;
        }
    }
}
