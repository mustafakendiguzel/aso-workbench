using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>The engine's preferences and the API connections, as the macOS app's Settings shows them.</summary>
public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly AsoClient client;
    private readonly StatusViewModel status;
    private EngineSettings? saved;

    public SettingsViewModel(AsoClient client, StatusViewModel status)
    {
        this.client = client;
        this.status = status;
        AppleAds = new AppleAdsConnectionViewModel(client, status, Refresh);
        AppStoreConnect = new AppStoreConnectConnectionViewModel(client, status, Refresh);
        OpenRouter = new OpenRouterConnectionViewModel(client, status, Refresh);
        RevenueCat = new RevenueCatConnectionViewModel(client, status, Refresh);
    }

    public static IReadOnlyList<int> ResultDepths { get; } = [50, 100, 200];
    public static IReadOnlyList<string> DeltaReferences { get; } = ["lastMarker", "previous", "first", "week"];
    public static IReadOnlyList<string> WriterModels { get; } =
        ["deepseek/deepseek-v4-pro", "deepseek/deepseek-v4-flash", "anthropic/claude-sonnet-5", "anthropic/claude-opus-5"];

    public AppleAdsConnectionViewModel AppleAds { get; }
    public AppStoreConnectConnectionViewModel AppStoreConnect { get; }
    public OpenRouterConnectionViewModel OpenRouter { get; }
    public RevenueCatConnectionViewModel RevenueCat { get; }

    [ObservableProperty] public partial int ResultDepth { get; set; } = 200;
    [ObservableProperty] public partial double PacingSeconds { get; set; } = 3.1;
    [ObservableProperty] public partial int GoldenMinPopularity { get; set; } = 30;
    [ObservableProperty] public partial int GoldenMaxDifficulty { get; set; } = 45;
    [ObservableProperty] public partial int WriterEasyDifficulty { get; set; } = 35;
    [ObservableProperty] public partial int WriterMaxDifficulty { get; set; } = 55;
    [ObservableProperty] public partial string DeltaReference { get; set; } = "lastMarker";
    [ObservableProperty] public partial bool AutoMeasureOnLaunch { get; set; }
    [ObservableProperty] public partial int StaleHours { get; set; } = 20;
    [ObservableProperty] public partial string WriterModel { get; set; } = "deepseek/deepseek-v4-pro";
    [ObservableProperty] public partial string AdsReferenceAppId { get; set; } = "";

    /// <summary>The settings as last loaded or saved, for the window's start-up refresh.</summary>
    public EngineSettings? Current => saved;

    [RelayCommand]
    private Task LoadAsync() => status.RunAsync("Loading settings…", async () =>
    {
        Show(await client.SettingsAsync().ConfigureAwait(true));
        await Refresh().ConfigureAwait(true);
        status.Info("Settings loaded.");
    });

    /// <summary>Sends only what changed; the engine checks every value against its range.</summary>
    [RelayCommand]
    private Task SaveAsync() => status.RunAsync("Saving settings…", async () =>
    {
        var changes = Changes().ToList();
        foreach (var (name, value) in changes) Show(await client.SetSettingAsync(name, value).ConfigureAwait(true));
        status.Info(changes.Count == 0 ? "Nothing changed." : $"Saved {changes.Count} setting(s).");
    });

    [RelayCommand]
    private Task ResetAsync() => status.RunAsync("Restoring defaults…", async () =>
    {
        Show(await client.ResetSettingsAsync().ConfigureAwait(true));
        status.Info("Settings are back to their defaults.");
    });

    /// <summary>Reloads the connection states (after a save, test or removal).</summary>
    public async Task Refresh()
    {
        var connections = await client.ConnectionsAsync().ConfigureAwait(true);
        foreach (var connection in connections)
        {
            ConnectionViewModel? target = connection.Service switch
            {
                "apple-ads" => AppleAds,
                "asc" => AppStoreConnect,
                "openrouter" => OpenRouter,
                "revenuecat" => RevenueCat,
                _ => null,
            };
            target?.Show(connection);
        }
    }

    internal IEnumerable<(string Name, string Value)> Changes()
    {
        if (saved is null) yield break;
        var invariant = CultureInfo.InvariantCulture;
        if (ResultDepth != saved.ResultDepth) yield return ("resultDepth", ResultDepth.ToString(invariant));
        if (Math.Abs(PacingSeconds - saved.PacingSeconds) > 0.0001) yield return ("pacingSeconds", Math.Round(PacingSeconds, 1).ToString(invariant));
        if (GoldenMinPopularity != saved.GoldenMinPopularity) yield return ("goldenMinPopularity", GoldenMinPopularity.ToString(invariant));
        if (GoldenMaxDifficulty != saved.GoldenMaxDifficulty) yield return ("goldenMaxDifficulty", GoldenMaxDifficulty.ToString(invariant));
        if (WriterEasyDifficulty != saved.WriterEasyDifficulty) yield return ("writerEasyDifficulty", WriterEasyDifficulty.ToString(invariant));
        if (WriterMaxDifficulty != saved.WriterMaxDifficulty) yield return ("writerMaxDifficulty", WriterMaxDifficulty.ToString(invariant));
        if (DeltaReference != saved.DeltaReference) yield return ("deltaReference", DeltaReference);
        if (AutoMeasureOnLaunch != saved.AutoMeasureOnLaunch) yield return ("autoMeasureOnLaunch", AutoMeasureOnLaunch ? "true" : "false");
        if (StaleHours != saved.StaleHours) yield return ("staleHours", StaleHours.ToString(invariant));
        if (WriterModel != saved.WriterModel) yield return ("writerModel", WriterModel.Trim());
        if (AdsReferenceAppId != saved.AdsReferenceAppId) yield return ("adsReferenceAppID", AdsReferenceAppId.Trim());
    }

    private void Show(EngineSettings settings)
    {
        saved = settings;
        ResultDepth = settings.ResultDepth;
        PacingSeconds = settings.PacingSeconds;
        GoldenMinPopularity = settings.GoldenMinPopularity;
        GoldenMaxDifficulty = settings.GoldenMaxDifficulty;
        WriterEasyDifficulty = settings.WriterEasyDifficulty;
        WriterMaxDifficulty = settings.WriterMaxDifficulty;
        DeltaReference = settings.DeltaReference;
        AutoMeasureOnLaunch = settings.AutoMeasureOnLaunch;
        StaleHours = settings.StaleHours;
        WriterModel = settings.WriterModel;
        AdsReferenceAppId = settings.AdsReferenceAppId;
        OnPropertyChanged(nameof(Current));
    }
}

/// <summary>One service's keys: what is stored (never the secret), and Save, Test and Remove.</summary>
public abstract partial class ConnectionViewModel(string service, AsoClient client, StatusViewModel status, Func<Task> refresh) : ObservableObject
{
    public string Service { get; } = service;
    protected AsoClient Client { get; } = client;
    protected StatusViewModel Status { get; } = status;
    public abstract string Title { get; }
    public abstract ConnectionGuide Guide { get; }

    [ObservableProperty] public partial bool IsConfigured { get; set; }

    /// <summary>Identifiers and the key fingerprint, e.g. "keyFingerprint a40f0f2e2974dc76".</summary>
    [ObservableProperty] public partial string Details { get; set; } = "";

    [ObservableProperty] public partial string? LastTest { get; set; }

    public string StatusText => IsConfigured ? "Stored" : "Not set";

    internal void Show(ConnectionStatus connection)
    {
        IsConfigured = connection.Configured;
        Details = string.Join(" · ", connection.Details.OrderBy(d => d.Key, StringComparer.Ordinal).Select(d => $"{d.Key} {d.Value}"));
        OnPropertyChanged(nameof(StatusText));
        TestCommand.NotifyCanExecuteChanged();
        RemoveCommand.NotifyCanExecuteChanged();
    }

    protected abstract bool CanSave();
    protected abstract Task<ConnectionStatus> SaveKeysAsync();
    /// <summary>Clears what was typed, so a secret does not stay in the window after it was stored.</summary>
    protected abstract void ClearInput();

    [RelayCommand(CanExecute = nameof(CanSave))]
    private Task SaveAsync() => Status.RunAsync($"Saving the {Title} keys…", async () =>
    {
        Show(await SaveKeysAsync().ConfigureAwait(true));
        ClearInput();
        Status.Info($"Saved the {Title} keys. Press Test connection to check them.");
    });

    private bool CanTest() => IsConfigured;

    [RelayCommand(CanExecute = nameof(CanTest))]
    private Task TestAsync() => Status.RunAsync($"Testing {Title}…", async () =>
    {
        LastTest = null;
        LastTest = await Client.VerifyConnectionAsync(Service).ConfigureAwait(true);
        Status.Info($"{Title}: {LastTest}");
    });

    [RelayCommand(CanExecute = nameof(CanTest))]
    private Task RemoveAsync() => Status.RunAsync($"Removing the {Title} keys…", async () =>
    {
        await Client.RemoveConnectionAsync(Service).ConfigureAwait(true);
        LastTest = null;
        await refresh().ConfigureAwait(true);
        Status.Info($"Removed the {Title} keys.");
    });

    protected void InputChanged() => SaveCommand.NotifyCanExecuteChanged();
}

public sealed partial class AppleAdsConnectionViewModel(AsoClient client, StatusViewModel status, Func<Task> refresh)
    : ConnectionViewModel("apple-ads", client, status, refresh)
{
    public override string Title => "Apple Ads";
    public override ConnectionGuide Guide => ConnectionGuides.AppleAds;

    [ObservableProperty] public partial string ClientId { get; set; } = "";
    [ObservableProperty] public partial string KeyId { get; set; } = "";
    [ObservableProperty] public partial string OrgId { get; set; } = "";
    /// <summary>The chosen .pem file; aso reads it itself.</summary>
    [ObservableProperty] public partial string KeyFilePath { get; set; } = "";

    partial void OnClientIdChanged(string value) => InputChanged();
    partial void OnKeyIdChanged(string value) => InputChanged();
    partial void OnOrgIdChanged(string value) => InputChanged();
    partial void OnKeyFilePathChanged(string value) => InputChanged();

    protected override bool CanSave() =>
        !string.IsNullOrWhiteSpace(ClientId) && !string.IsNullOrWhiteSpace(KeyId) && !string.IsNullOrWhiteSpace(OrgId) && !string.IsNullOrWhiteSpace(KeyFilePath);

    protected override Task<ConnectionStatus> SaveKeysAsync() =>
        Client.SaveAppleAdsAsync(ClientId.Trim(), KeyId.Trim(), OrgId.Trim(), KeySource.File(KeyFilePath));

    protected override void ClearInput() => KeyFilePath = "";
}

public sealed partial class AppStoreConnectConnectionViewModel(AsoClient client, StatusViewModel status, Func<Task> refresh)
    : ConnectionViewModel("asc", client, status, refresh)
{
    public override string Title => "App Store Connect";
    public override ConnectionGuide Guide => ConnectionGuides.AppStoreConnect;

    [ObservableProperty] public partial string IssuerId { get; set; } = "";
    /// <summary>Optional when the file keeps Apple's name, AuthKey_&lt;KEYID&gt;.p8.</summary>
    [ObservableProperty] public partial string KeyId { get; set; } = "";
    [ObservableProperty] public partial string KeyFilePath { get; set; } = "";

    partial void OnIssuerIdChanged(string value) => InputChanged();
    partial void OnKeyFilePathChanged(string value) => InputChanged();

    protected override bool CanSave() => !string.IsNullOrWhiteSpace(IssuerId) && !string.IsNullOrWhiteSpace(KeyFilePath);

    protected override Task<ConnectionStatus> SaveKeysAsync() =>
        Client.SaveAppStoreConnectAsync(string.IsNullOrWhiteSpace(KeyId) ? null : KeyId.Trim(), IssuerId.Trim(), KeySource.File(KeyFilePath));

    protected override void ClearInput() => KeyFilePath = "";
}

public sealed partial class OpenRouterConnectionViewModel(AsoClient client, StatusViewModel status, Func<Task> refresh)
    : ConnectionViewModel("openrouter", client, status, refresh)
{
    public override string Title => "OpenRouter";
    public override ConnectionGuide Guide => ConnectionGuides.OpenRouter;

    [ObservableProperty] public partial string ApiKey { get; set; } = "";

    partial void OnApiKeyChanged(string value) => InputChanged();

    protected override bool CanSave() => !string.IsNullOrWhiteSpace(ApiKey);
    protected override Task<ConnectionStatus> SaveKeysAsync() => Client.SaveOpenRouterKeyAsync(ApiKey.Trim());
    protected override void ClearInput() => ApiKey = "";
}

public sealed partial class RevenueCatConnectionViewModel(AsoClient client, StatusViewModel status, Func<Task> refresh)
    : ConnectionViewModel("revenuecat", client, status, refresh)
{
    public override string Title => "RevenueCat";
    public override ConnectionGuide Guide => ConnectionGuides.RevenueCat;

    [ObservableProperty] public partial string Keys { get; set; } = "";

    partial void OnKeysChanged(string value) => InputChanged();

    protected override bool CanSave() => !string.IsNullOrWhiteSpace(Keys);
    protected override Task<ConnectionStatus> SaveKeysAsync() => Client.SaveRevenueCatKeysAsync(Keys);
    protected override void ClearInput() => Keys = "";
}
