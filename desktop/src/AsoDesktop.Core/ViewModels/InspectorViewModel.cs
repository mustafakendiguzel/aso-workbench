using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>One point of the rank chart. <c>Rank</c> is null when the app was not among <c>ObservedCount</c> results.</summary>
public sealed record RankChartPoint(DateTimeOffset At, int? Rank, int ObservedCount);

/// <summary>The keyword inspector: rank history, top results, difficulty and the note of the selected keyword.</summary>
public sealed partial class InspectorViewModel(AsoClient client, StatusViewModel status) : ObservableObject
{
    public static IReadOnlyList<string> Ranges { get; } = ["7D", "30D", "90D", "All"];

    private (long App, string Country, string Device, string Keyword)? target;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ChartPoints), nameof(HasDetail), nameof(SummaryText))]
    [NotifyCanExecuteChangedFor(nameof(SaveNoteCommand))]
    public partial KeywordDetail? Detail { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ChartPoints))]
    public partial string Range { get; set; } = "30D";

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(SaveNoteCommand))]
    public partial string NoteText { get; set; } = "";

    public bool HasDetail => Detail is not null;

    /// <summary>The measurements inside the chosen range, counted back from the latest one (failures leave gaps).</summary>
    public IReadOnlyList<RankChartPoint> ChartPoints => Points(Detail, Range);

    public string SummaryText => Detail is not { Summary: var s } ? "" :
        $"Latest {(s.Latest is { } l ? $"#{l}" : "not found")} · best {(s.Best is { } b ? $"#{b}" : "—")} · " +
        $"{s.Measurements} measurement(s), {s.Outside} outside the results";

    public static IReadOnlyList<RankChartPoint> Points(KeywordDetail? detail, string range)
    {
        if (detail is null) return [];
        var measured = detail.Observations.Where(o => o.Status is "found" or "outside").ToList();
        if (measured.Count == 0) return [];
        var days = range switch { "7D" => 7, "30D" => 30, "90D" => 90, _ => (int?)null };
        var from = days is { } d ? measured[^1].FetchedAt.AddDays(-d) : DateTimeOffset.MinValue;
        return measured.Where(o => o.FetchedAt >= from).Select(o => new RankChartPoint(o.FetchedAt, o.Rank, o.ObservedCount)).ToList();
    }

    /// <summary>Loads the keyword, or clears the inspector when nothing is selected.</summary>
    public Task ShowAsync(AppRecord? app, MarketSummary? market, KeywordRow? row, string delta)
    {
        if (app is null || market is null || row is null)
        {
            target = null;
            Detail = null;
            NoteText = "";
            return Task.CompletedTask;
        }
        target = (app.TrackId, market.Country, market.Device, row.Keyword);
        return status.RunAsync($"Loading {row.Keyword}…", async () =>
        {
            var wanted = target;
            var detail = await client.KeywordDetailAsync(app.TrackId, row.Keyword, market.Country, market.Device, delta).ConfigureAwait(true);
            if (target != wanted) return;   // another keyword was selected meanwhile
            Detail = detail;
            NoteText = detail.Row.Note;
            status.Info($"{row.Keyword}: {SummaryText}.");
        });
    }

    private bool CanSaveNote() => Detail is not null && NoteText.Trim() != Detail.Row.Note;

    [RelayCommand(CanExecute = nameof(CanSaveNote))]
    private Task SaveNoteAsync() => target is not { } t || Detail is not { } detail ? Task.CompletedTask : status.RunAsync("Saving the note…", async () =>
    {
        var note = NoteText.Trim();
        await client.SetNoteAsync(t.App, t.Keyword, t.Country, t.Device, note).ConfigureAwait(true);
        Detail = detail with { Row = detail.Row with { Note = note } };
        NoteText = note;
        status.Info(note.Length == 0 ? "Cleared the note." : "Saved the note.");
    });

    /// <summary>"12 May 14:05" in the user's culture, for the observation log.</summary>
    public static string When(DateTimeOffset at) => at.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
}
