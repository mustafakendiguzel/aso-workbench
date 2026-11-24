using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>Look-ups that store nothing: search results, autocomplete and difficulty for a term right now.</summary>
public sealed partial class ResearchViewModel(AsoClient client, StatusViewModel status) : ObservableObject
{
    public ObservableCollection<SearchResultApp> Results { get; } = [];
    public ObservableCollection<string> Hints { get; } = [];

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(SearchCommand), nameof(HintsCommand), nameof(DifficultyCommand))]
    public partial string Term { get; set; } = "";

    [ObservableProperty]
    public partial string Country { get; set; } = "US";

    [ObservableProperty]
    public partial string Device { get; set; } = "iphone";

    [ObservableProperty]
    public partial DifficultyReport? Difficulty { get; set; }

    private bool HasTerm() => !string.IsNullOrWhiteSpace(Term);

    [RelayCommand(CanExecute = nameof(HasTerm))]
    private Task SearchAsync() => status.RunAsync($"Searching \"{Term.Trim()}\"…", async () =>
    {
        var results = await client.SearchAsync(Term.Trim(), Country.Trim(), Device).ConfigureAwait(true);
        Replace(Results, results);
        status.Info($"{results.Count} result(s) for \"{Term.Trim()}\" in {Country.Trim().ToUpperInvariant()}.");
    });

    [RelayCommand(CanExecute = nameof(HasTerm))]
    private Task HintsAsync() => status.RunAsync($"Autocomplete for \"{Term.Trim()}\"…", async () =>
    {
        var hints = await client.HintsAsync(Term.Trim(), Country.Trim()).ConfigureAwait(true);
        Replace(Hints, hints);
        status.Info(hints.Count == 0 ? "No suggestions." : $"{hints.Count} suggestion(s).");
    });

    [RelayCommand(CanExecute = nameof(HasTerm))]
    private Task DifficultyAsync() => status.RunAsync($"Scoring \"{Term.Trim()}\"…", async () =>
    {
        Difficulty = await client.DifficultyAsync(Term.Trim(), Country.Trim(), Device).ConfigureAwait(true);
        status.Info($"Difficulty {Math.Round(Difficulty.Score)} of 100 ({Difficulty.Tier}).");
    });

    /// <summary>Uses a suggestion as the new term.</summary>
    [RelayCommand]
    private void UseHint(string? hint)
    {
        if (!string.IsNullOrWhiteSpace(hint)) Term = hint;
    }

    private static void Replace<T>(ObservableCollection<T> target, IEnumerable<T> items)
    {
        target.Clear();
        foreach (var item in items) target.Add(item);
    }
}
