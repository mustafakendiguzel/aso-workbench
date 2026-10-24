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
    }

    public StatusViewModel Status { get; } = new();
    public KeywordsViewModel Keywords { get; }
    public ResearchViewModel Research { get; }
    public MetadataViewModel Metadata { get; }

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

    [RelayCommand]
    private Task LoadAsync() => Status.RunAsync("Loading tracked apps…", async () =>
    {
        EngineVersion = await client.VersionAsync().ConfigureAwait(true);
        await ReloadAppsAsync(keepSelection: null).ConfigureAwait(true);
        Status.Info(Apps.Count == 0 ? "No apps yet. Paste an App Store link on the left to start." : $"{Apps.Count} tracked app(s).");
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
