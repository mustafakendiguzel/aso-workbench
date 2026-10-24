using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>A release or note on the timeline.</summary>
public sealed record MarkerLine(Marker Marker)
{
    public string Kind => Marker.IsRelease ? "Release" : "Note";
    public bool IsRelease => Marker.IsRelease;
    public string Title => Marker.Title;
    public string Date => Marker.Date.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
    public string? SeenIn => Marker.Country is { } c ? $"seen in {c}" : null;
}

/// <summary>One keyword's move around the marker as the impact table shows it.</summary>
public sealed record ImpactLine(ImpactRow Row)
{
    public string Keyword => Row.Keyword;
    public string Market => $"{Row.Country} · {Row.Device}";
    public string Before => Rank(Row.Before);
    public string After => Rank(Row.After);
    public string BeforeAt => Row.BeforeAt.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
    public string AfterAt => Row.AfterAt.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
    public int Delta => Row.Delta;
    public string DeltaText => Row.Delta switch { > 0 => $"+{Row.Delta}", 0 => "—", _ => Row.Delta.ToString(CultureInfo.CurrentCulture) };
    public bool IsUp => Row.Delta > 0;
    public bool IsDown => Row.Delta < 0;
    public string Tier => Row.Tier;
    public double Value => Row.Value;
    public bool HasValue => Row.Value > 0;
    public string Components => $"pop {Number(Row.Popularity)} · diff {Number(Row.Difficulty)}"
                                + (Row.Fit is { } fit ? $" · fit {(fit * 100).ToString("0", CultureInfo.CurrentCulture)}%" : "");
    public string ValueHint => $"Value {Math.Round(Row.Value).ToString(CultureInfo.CurrentCulture)}/100: popularity {Number(Row.Popularity)}, "
                               + $"difficulty {(Row.Difficulty is null ? "unmeasured (50 assumed)" : Number(Row.Difficulty))}, "
                               + $"fit {(Row.Fit is { } f ? (f * 100).ToString("0", CultureInfo.CurrentCulture) + "%" : "unchecked")}"
                               + (Row.BrandLike ? "; a brand term is worth nothing" : "") + ".";
    public double Gain => Row.Gain;
    public string GainText => HasValue ? Row.Gain.ToString("+0.00;-0.00;0.00", CultureInfo.CurrentCulture) : "0 · no value";
    public bool Gained => HasValue && Row.Gain > 0;
    public bool Lost => HasValue && Row.Gain < 0;

    private string Rank(int? position) => position is { } p ? $"#{p}" : $"> {Row.Depth}";
    private static string Number(int? value) => value?.ToString(CultureInfo.CurrentCulture) ?? "?";
    private static string Number(double? value) => value is { } v ? Math.Round(v).ToString(CultureInfo.CurrentCulture) : "?";
}

/// <summary>
/// The Changes tab: App Store releases (recorded when the app is measured or its ratings are checked) and notes, and for the
/// selected one the ranks before and after it, weighted by what each keyword is worth, as in the macOS app.
/// </summary>
public sealed partial class ChangesViewModel(AsoClient client, StatusViewModel status, Func<DateTimeOffset>? clock = null) : ObservableObject
{
    public const string AllMarkets = "All markets";
    public static IReadOnlyList<string> Modes { get; } = ["Improved", "Worsened", "All"];
    public static IReadOnlyList<string> ValueFilters { get; } = ["Any value", "Low and above", "Medium and above", "High only"];

    /// <summary>The lowest value each entry of <see cref="ValueFilters"/> keeps (the engine's tier thresholds).</summary>
    private static readonly double[] ValueThresholds = [0, 0.01, 15, 40];

    private readonly Func<DateTimeOffset> now = clock ?? (() => DateTimeOffset.Now);

    public ObservableCollection<MarkerLine> Markers { get; } = [];
    public ObservableCollection<ImpactLine> Visible { get; } = [];
    public ObservableCollection<string> MarketFilters { get; } = [AllMarkets];

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddNoteCommand))]
    public partial AppRecord? App { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(RemoveSelectedCommand))]
    public partial MarkerLine? Selected { get; set; }

    [ObservableProperty] public partial ImpactReport? Report { get; set; }
    [ObservableProperty] public partial string Mode { get; set; } = "Improved";
    [ObservableProperty] public partial string MarketFilter { get; set; } = AllMarkets;
    [ObservableProperty] public partial string ValueFilter { get; set; } = "Any value";
    [ObservableProperty] public partial string Search { get; set; } = "";

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddNoteCommand))]
    public partial string NoteTitle { get; set; } = "";

    [ObservableProperty] public partial DateTimeOffset? NoteDate { get; set; }
    [ObservableProperty] public partial TimeSpan? NoteTime { get; set; }

    public bool HasMarkers => Markers.Count > 0;
    public bool HasSelection => Selected is not null;
    public bool HasRows => Report is { Rows.Count: > 0 };

    public string Headline => Selected is { } s ? $"Effect of {s.Title} · {s.Date}" : "";

    public string EmptyImpact => Selected is { } s && Report is { Rows.Count: 0 }
        ? $"No keyword has a measurement both before and after {s.Date}. Measure before a change and keep measuring after it; the comparison appears here."
        : "";

    public string Net => Report is { } r ? r.Net.ToString("+0.0;-0.0;0.0", CultureInfo.CurrentCulture) : "";
    public bool NetIsUp => Report is { Net: > 0.5 };
    public bool NetIsDown => Report is { Net: < -0.5 };
    public string Gained => Report is { } r ? "+" + r.Gained.ToString("0.0", CultureInfo.CurrentCulture) : "";
    public string Lost => Report is { } r ? r.Lost.ToString("0.0", CultureInfo.CurrentCulture) : "";
    public string Counts => Report is { } r ? $"{r.Improved} · {r.Worsened} · {r.Same}" : "";
    public string Shown => Report is { } r ? $"{Visible.Count} of {r.Rows.Count}" : "";

    /// <summary>Without popularity (Apple Ads, a later step) every keyword is worth 0 and the totals stay at 0; the moves still show.</summary>
    public bool NoValues => Report is { Rows.Count: > 0 } r && r.Rows.All(row => row.Value == 0);

    partial void OnAppChanged(AppRecord? oldValue, AppRecord? newValue)
    {
        if (oldValue?.TrackId == newValue?.TrackId) return;
        Markers.Clear();
        Selected = null;
        OnPropertyChanged(nameof(HasMarkers));
        if (newValue is not null) _ = status.QuietlyAsync(ReloadAsync);
    }

    partial void OnSelectedChanged(MarkerLine? value)
    {
        Report = null;
        OnPropertyChanged(nameof(HasSelection));
        OnPropertyChanged(nameof(Headline));
        if (value is not null) _ = status.QuietlyAsync(LoadImpactAsync);
    }

    partial void OnReportChanged(ImpactReport? value)
    {
        var keep = MarketFilter;
        MarketFilters.Clear();
        MarketFilters.Add(AllMarkets);
        foreach (var market in (value?.Rows ?? []).Select(r => $"{r.Country} · {r.Device}").Distinct().Order(StringComparer.Ordinal)) MarketFilters.Add(market);
        MarketFilter = MarketFilters.Contains(keep) ? keep : AllMarkets;
        ApplyFilters();
        foreach (var name in (string[])[nameof(HasRows), nameof(EmptyImpact), nameof(Net), nameof(NetIsUp), nameof(NetIsDown), nameof(Gained),
                                         nameof(Lost), nameof(Counts), nameof(NoValues)])
            OnPropertyChanged(name);
    }

    partial void OnModeChanged(string value) => ApplyFilters();
    partial void OnMarketFilterChanged(string value) => ApplyFilters();
    partial void OnValueFilterChanged(string value) => ApplyFilters();
    partial void OnSearchChanged(string value) => ApplyFilters();

    /// <summary>Reads the timeline again, keeping the selected marker when it is still there.</summary>
    public async Task ReloadAsync()
    {
        if (App is not { } app) return;
        var markers = await client.MarkersAsync(app.TrackId).ConfigureAwait(true);
        if (App?.TrackId != app.TrackId) return;   // the selection moved on while loading
        var keep = Selected?.Marker.Id;
        Markers.Clear();
        foreach (var marker in markers) Markers.Add(new MarkerLine(marker));
        OnPropertyChanged(nameof(HasMarkers));
        Selected = null;   // re-selecting reads the impact again, with the latest ranks
        Selected = Markers.FirstOrDefault(m => m.Marker.Id == keep);
    }

    private async Task LoadImpactAsync()
    {
        if (App is not { } app || Selected is not { } selected) return;
        var report = await client.ImpactAsync(app.TrackId, selected.Marker.Id).ConfigureAwait(true);
        if (App?.TrackId == app.TrackId && Selected?.Marker.Id == selected.Marker.Id) Report = report;
    }

    private bool CanAddNote() => App is not null && NoteTitle.Trim().Length > 0;

    /// <summary>Pins a note to the chosen day and time (now when none is chosen).</summary>
    [RelayCommand(CanExecute = nameof(CanAddNote))]
    private Task AddNoteAsync() => App is not { } app ? Task.CompletedTask : status.RunAsync("Adding the note…", async () =>
    {
        var at = NoteMoment(NoteDate, NoteTime, now());
        var marker = await client.AddNoteAsync(app.TrackId, NoteTitle.Trim(), at).ConfigureAwait(true);
        NoteTitle = "";
        NoteDate = null;
        NoteTime = null;
        await ReloadAsync().ConfigureAwait(true);
        Selected = Markers.FirstOrDefault(m => m.Marker.Id == marker.Id);
        status.Info($"Added the note “{marker.Title}”.");
    });

    /// <summary>The chosen day (local) at the chosen time; the day alone means now's time on that day, nothing means now.</summary>
    internal static DateTimeOffset NoteMoment(DateTimeOffset? date, TimeSpan? time, DateTimeOffset now)
    {
        if (date is null && time is null) return now;
        var local = now.ToLocalTime();
        var day = (date?.ToLocalTime() ?? local).Date;
        var moment = day + (time ?? local.TimeOfDay);
        return new DateTimeOffset(moment, TimeZoneInfo.Local.GetUtcOffset(moment));
    }

    /// <summary>Removes the selected marker; the view asks first.</summary>
    [RelayCommand(CanExecute = nameof(HasSelection))]
    private Task RemoveSelectedAsync() => App is not { } app || Selected is not { } selected ? Task.CompletedTask :
        status.RunAsync("Removing the marker…", async () =>
        {
            await client.RemoveMarkerAsync(app.TrackId, selected.Marker.Id).ConfigureAwait(true);
            Selected = null;
            await ReloadAsync().ConfigureAwait(true);
            status.Info($"Removed the {(selected.IsRelease ? "release" : "note")} “{selected.Title}”.");
        });

    private void ApplyFilters()
    {
        var rows = (Report?.Rows ?? []).Select(r => new ImpactLine(r));
        rows = Mode switch
        {
            "Improved" => rows.Where(r => r.Delta > 0).OrderByDescending(r => r.Gain).ThenByDescending(r => r.Delta),
            "Worsened" => rows.Where(r => r.Delta < 0).OrderBy(r => r.Gain).ThenBy(r => r.Delta),
            _ => rows,
        };
        if (MarketFilter != AllMarkets) rows = rows.Where(r => r.Market == MarketFilter);
        var threshold = ValueThresholds[Math.Max(0, ValueFilters.ToList().IndexOf(ValueFilter))];
        if (threshold > 0) rows = rows.Where(r => r.Value >= threshold);
        var search = Search.Trim();
        // Ordinal: a culture-aware comparison breaks under Turkish casing.
        if (search.Length > 0) rows = rows.Where(r => r.Keyword.Contains(search, StringComparison.OrdinalIgnoreCase));
        Visible.Clear();
        foreach (var row in rows) Visible.Add(row);
        OnPropertyChanged(nameof(Shown));
    }
}
