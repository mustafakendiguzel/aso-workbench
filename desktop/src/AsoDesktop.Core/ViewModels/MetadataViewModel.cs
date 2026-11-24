using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>Checks title, subtitle and keyword field against the App Store rules the engine knows.</summary>
public sealed partial class MetadataViewModel(AsoClient client, StatusViewModel status) : ObservableObject
{
    public ObservableCollection<ValidationIssue> Issues { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(TitleLength))]
    public partial string Title { get; set; } = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SubtitleLength))]
    public partial string Subtitle { get; set; } = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(KeywordsLength))]
    public partial string Keywords { get; set; } = "";

    // Characters as the App Store counts them (Unicode code points, not UTF-16 units); the limits come from the engine's check.
    public int TitleLength => CodePoints(Title);
    public int SubtitleLength => CodePoints(Subtitle);
    public int KeywordsLength => CodePoints(Keywords);

    public static int CodePoints(string text) => text.EnumerateRunes().Count();

    [RelayCommand]
    private Task CheckAsync() => status.RunAsync("Checking metadata…", async () =>
    {
        var issues = await client.ValidateAsync(Title, Subtitle, Keywords).ConfigureAwait(true);
        Issues.Clear();
        foreach (var issue in issues.OrderByDescending(i => i.Severity)) Issues.Add(issue);
        var errors = issues.Count(i => i.Severity == ValidationSeverity.Error);
        if (errors > 0) status.Error($"{errors} error(s): App Store Connect would refuse this metadata.");
        else status.Info(issues.Count == 0 ? "No issues." : $"{issues.Count} suggestion(s), no errors.");
    });
}
