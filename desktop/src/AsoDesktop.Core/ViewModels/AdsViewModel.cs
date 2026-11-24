using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>One storefront of the app's campaigns, as the card shows it.</summary>
public sealed record AdsLine(AdsStorefront Row)
{
    public string Storefront => $"{Row.CountryName} ({Row.Country})";
    public string Impressions => Row.Impressions.ToString("N0", CultureInfo.CurrentCulture);
    public string Taps => Row.Taps.ToString("N0", CultureInfo.CurrentCulture);
    public string Installs => Row.Installs.ToString("N0", CultureInfo.CurrentCulture);
    public string Spend => $"{Row.Spend.ToString("0.00", CultureInfo.CurrentCulture)} {Row.Currency}";
    public string CostPerInstall => Row.CostPerInstall is { } c ? c.ToString("0.00", CultureInfo.CurrentCulture) : "—";
    public string TapToInstall => Row.TapToInstall is { } r ? r.ToString("P0", CultureInfo.CurrentCulture) : "—";
}

/// <summary>The macOS app's "Apple Ads · your campaigns" card: the app's own results per storefront, and Sync.</summary>
public sealed partial class AdsViewModel(AsoClient client, StatusViewModel status) : ObservableObject
{
    public ObservableCollection<AdsLine> Rows { get; } = [];

    [ObservableProperty] public partial AppRecord? App { get; set; }

    /// <summary>Apple Ads keys are stored; the campaigns use the same ones as popularity.</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(SyncCommand))]
    public partial bool AdsConnected { get; set; }

    [ObservableProperty] public partial string Headline { get; set; } = "";
    [ObservableProperty] public partial bool HasRows { get; set; }

    /// <summary>Runs after a sync: the keyword table shows each keyword's results.</summary>
    public Func<Task>? Synced { get; set; }

    partial void OnAppChanged(AppRecord? oldValue, AppRecord? newValue)
    {
        if (oldValue?.TrackId == newValue?.TrackId) return;
        Show(null);
        if (newValue is not null) _ = status.QuietlyAsync(ReloadAsync);
    }

    public async Task ReloadAsync()
    {
        if (App is not { } app) return;
        var report = await client.AdsAsync(app.TrackId).ConfigureAwait(true);
        if (App?.TrackId == app.TrackId) Show(report);   // the selection may have moved on while loading
    }

    /// <summary>Every tracked app's campaigns, the last 30 days, as the macOS card's Sync does.</summary>
    [RelayCommand(CanExecute = nameof(AdsConnected))]
    private Task SyncAsync() => status.RunAsync("Reading your Apple Ads campaigns…", async () =>
    {
        var sync = await client.SyncAdsAsync().ConfigureAwait(true);
        await ReloadAsync().ConfigureAwait(true);
        if (Synced is not null) await Synced().ConfigureAwait(true);
        status.Info($"{sync.Campaigns} campaign(s) in the account, {sync.Matched} for tracked apps; {sync.Rows} keyword × storefront row(s) for the last 30 days.");
    });

    private void Show(AdsReport? report)
    {
        Rows.Clear();
        foreach (var row in report?.Storefronts ?? []) Rows.Add(new AdsLine(row));
        HasRows = Rows.Count > 0;
        Headline = report is { SyncedAt: { } synced, PeriodStart: { } start, PeriodEnd: { } end }
            ? $"{Day(start)} to {Day(end)}, synced {synced.ToLocalTime().ToString("g", CultureInfo.CurrentCulture)}"
            :"Your own campaign results: the ground truth for demand and cost per storefront. Sync reads the last 30 days for every tracked app.";
    }

    private static string Day(DateTimeOffset date) => date.UtcDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
}
