using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>One day of the project's history, as the card's table shows it.</summary>
public sealed record RevenueLine(RevenueSnapshot Row)
{
    public string Read => Row.FetchedAt.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
    public string Mrr => RevenueViewModel.Dollars(Row.Mrr);
    public string Subscriptions => Row.ActiveSubscriptions.ToString("N0", CultureInfo.CurrentCulture);
    public string Revenue => RevenueViewModel.Dollars(Row.Revenue28d);
    public string NewCustomers => Row.NewCustomers28d.ToString("N0", CultureInfo.CurrentCulture);
    public string Trials => Row.ActiveTrials.ToString("N0", CultureInfo.CurrentCulture);
}

/// <summary>The macOS app's "Revenue · RevenueCat" card: MRR and subscription counts for the app's project, with its daily history.</summary>
public sealed partial class RevenueViewModel(AsoClient client, StatusViewModel status) : ObservableObject
{
    public ObservableCollection<RevenueLine> History { get; } = [];

    [ObservableProperty] public partial AppRecord? App { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(RefreshCommand))]
    [NotifyPropertyChangedFor(nameof(Headline))]
    public partial bool RevenueConnected { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Headline), nameof(HasLatest), nameof(Mrr), nameof(MrrChange), nameof(Subscriptions), nameof(Revenue),
                              nameof(NewCustomers), nameof(Trials), nameof(HasHistory))]
    public partial RevenueReport? Report { get; set; }

    public bool HasLatest => Report?.Latest is not null;
    public bool HasHistory => History.Count > 1;

    public string Headline => !RevenueConnected
        ? "Add RevenueCat secret API keys in Settings, Connections to see MRR, active subscriptions and 28-day revenue here."
        : Report?.Latest is { } s
            ? $"{s.ProjectName} · read {s.FetchedAt.ToLocalTime().ToString("g", CultureInfo.CurrentCulture)}"
              + (s.AppNames.Count > 1 ? $" · the project holds {s.AppNames.Count} apps ({string.Join(", ", s.AppNames)})" : "")
            : $"No RevenueCat project matches this app (bundle {App?.BundleId ?? "?"}). Press Refresh; projects are matched by bundle ID, then by name.";

    public string Mrr => Report?.Latest is { } s ? Dollars(s.Mrr) : "";
    public string MrrChange => Report?.MrrChange is { } c && Math.Round(c) != 0 ? (c > 0 ? "+" : "−") + Dollars(Math.Abs(c)) : "";
    public string Subscriptions => Report?.Latest?.ActiveSubscriptions.ToString("N0", CultureInfo.CurrentCulture) ?? "";
    public string Revenue => Report?.Latest is { } s ? Dollars(s.Revenue28d) : "";
    public string NewCustomers => Report?.Latest?.NewCustomers28d.ToString("N0", CultureInfo.CurrentCulture) ?? "";
    public string Trials => Report?.Latest?.ActiveTrials.ToString("N0", CultureInfo.CurrentCulture) ?? "";

    /// <summary>"$1,234", whole dollars, as the macOS card shows them.</summary>
    public static string Dollars(double value) => "$" + Math.Round(value).ToString("N0", CultureInfo.CurrentCulture);

    partial void OnAppChanged(AppRecord? oldValue, AppRecord? newValue)
    {
        if (oldValue?.TrackId == newValue?.TrackId) return;
        Show(null);
        if (newValue is not null) _ = status.QuietlyAsync(ReloadAsync);
    }

    public async Task ReloadAsync()
    {
        if (App is not { } app) return;
        var report = await client.RevenueAsync(app.TrackId).ConfigureAwait(true);
        if (App?.TrackId == app.TrackId) Show(report);   // the selection may have moved on while loading
    }

    /// <summary>Reads every project now, as the macOS app does on demand and once per launch.</summary>
    [RelayCommand(CanExecute = nameof(RevenueConnected))]
    private Task RefreshAsync() => status.RunAsync("Reading RevenueCat…", async () =>
    {
        var refresh = await client.RefreshRevenueAsync().ConfigureAwait(true);
        await ReloadAsync().ConfigureAwait(true);
        status.Info($"{refresh.Projects} RevenueCat project(s) read."
                    + (refresh.Failures.Count == 0 ? "" : $" {refresh.Failures.Count} key(s) failed: {refresh.Failures[0]}"));
    });

    private void Show(RevenueReport? report)
    {
        History.Clear();
        foreach (var row in report?.History ?? []) History.Add(new RevenueLine(row));
        Report = report;
    }
}
