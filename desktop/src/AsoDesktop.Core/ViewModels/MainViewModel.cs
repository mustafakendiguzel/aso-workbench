using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>The window: tracked apps on the left, the selected app's keywords, research and metadata on the right.</summary>
public sealed partial class MainViewModel : ObservableObject
{
    private readonly AsoClient client;

    public MainViewModel(AsoClient client)
    {
        this.client = client;
        Keywords = new KeywordsViewModel(client, Status);
        Research = new ResearchViewModel(client, Status);
        Metadata = new MetadataViewModel(client, Status);
        Settings = new SettingsViewModel(client, Status);
    }

    public StatusViewModel Status { get; } = new();
    public KeywordsViewModel Keywords { get; }
    public ResearchViewModel Research { get; }
    public MetadataViewModel Metadata { get; }
    public SettingsViewModel Settings { get; }

    public ObservableCollection<AppRecord> Apps { get; } = [];

    [ObservableProperty]
    public partial AppRecord? SelectedApp { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddAppCommand))]
    public partial string NewAppReference { get; set; } = "";

    [ObservableProperty]
    public partial string NewAppCountry { get; set; } = "US";

    [ObservableProperty]
    public partial string? EngineVersion { get; set; }

    /// <summary>Where the engine keeps engine.sqlite, settings.json and credentials.json.</summary>
    [ObservableProperty]
    public partial string? DataDirectory { get; set; }

    /// <summary>Start-up: engine version, settings, connections and apps; then, if the setting is on, the stale-market refresh.</summary>
    [RelayCommand]
    private async Task LoadAsync()
    {
        await Settings.LoadCommand.ExecuteAsync(null).ConfigureAwait(true);
        await Status.RunAsync("Loading tracked apps…", async () =>
        {
            var engine = await client.EngineInfoAsync().ConfigureAwait(true);
            EngineVersion = engine.Version;
            DataDirectory = engine.DataDirectory;
            await ReloadAppsAsync(keepSelection: null).ConfigureAwait(true);
            Status.Info(Apps.Count == 0 ? "No apps yet. Paste an App Store link on the left to start." : $"{Apps.Count} tracked app(s).");
        }).ConfigureAwait(true);
        if (Settings.Current?.AutoMeasureOnLaunch == true) await MeasureStaleCommand.ExecuteAsync(null).ConfigureAwait(true);
    }

    /// <summary>Measures every market not measured within the stale-hours setting, as the macOS app does when it opens.</summary>
    [RelayCommand(IncludeCancelCommand = true)]
    private Task MeasureStaleAsync(CancellationToken cancellationToken) =>
        Status.RunAsync("Refreshing markets not measured recently…", async () =>
        {
            var progress = new Progress<MeasureStep>(step => Status.Info($"Refreshing {step.Completed}/{step.Total}: {step.Keyword} in {step.Market}"));
            var summary = await client.MeasureStaleAsync(progress, cancellationToken).ConfigureAwait(true);
            if (Keywords.App is not null) await Keywords.RefreshCommand.ExecuteAsync(null).ConfigureAwait(true);
            Status.Info(summary.Measured == 0
                ? "Every market was measured recently."
                : $"Refreshed {summary.Measured} keyword(s): {summary.Found} ranked, {summary.Outside} outside, {summary.Failed} failed.");
        });

    private bool CanAddApp() => !string.IsNullOrWhiteSpace(NewAppReference);

    [RelayCommand(CanExecute = nameof(CanAddApp))]
    private Task AddAppAsync() => Status.RunAsync("Looking the app up…", async () =>
    {
        var app = await client.AddAppAsync(NewAppReference.Trim(), NewAppCountry.Trim()).ConfigureAwait(true);
        NewAppReference = "";
        await ReloadAppsAsync(keepSelection: app.TrackId).ConfigureAwait(true);
        Status.Info($"Tracking {app.Name}.");
    });

    [RelayCommand]
    private Task RemoveAppAsync(AppRecord? app) => app is null ? Task.CompletedTask : Status.RunAsync($"Removing {app.Name}…", async () =>
    {
        await client.RemoveAppAsync(app.TrackId).ConfigureAwait(true);
        await ReloadAppsAsync(keepSelection: null).ConfigureAwait(true);
        Status.Info($"Removed {app.Name} with its keywords and measurements.");
    });

    partial void OnSelectedAppChanged(AppRecord? value)
    {
        Keywords.App = value;
        if (value is not null) Keywords.RefreshCommand.Execute(null);
    }

    private async Task ReloadAppsAsync(long? keepSelection)
    {
        var selected = keepSelection ?? SelectedApp?.TrackId;
        var apps = await client.ListAppsAsync().ConfigureAwait(true);
        Apps.Clear();
        foreach (var app in apps) Apps.Add(app);
        SelectedApp = Apps.FirstOrDefault(a => a.TrackId == selected) ?? Apps.FirstOrDefault();
    }
}
