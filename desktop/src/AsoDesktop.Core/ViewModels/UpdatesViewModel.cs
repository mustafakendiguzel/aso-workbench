using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>
/// The macOS app's update checker for Windows and Linux: at start-up (when the setting is on) and on request, aso asks GitHub for the latest
/// release; a newer one shows in the sidebar with its notes, the release page and this platform's download. Skip hides it from automatic
/// checks. Nothing is downloaded or installed by the window.
/// </summary>
public sealed partial class UpdatesViewModel(AsoClient client, StatusViewModel status) : ObservableObject
{
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasUpdate), nameof(Banner), nameof(Heading), nameof(Notes), nameof(Published), nameof(CanDownload))]
    [NotifyCanExecuteChangedFor(nameof(SkipCommand), nameof(LaterCommand))]
    public partial ReleaseInfo? Available { get; set; }

    [ObservableProperty] public partial string? Current { get; set; }

    public bool HasUpdate => Available is not null;
    public string Banner => Available is { } r ? $"Version {r.Version} is available" : "";
    public string Heading => Available is { } r ? $"{r.Title} (you have {Current ?? "?"})" : "";
    public string Notes => Available is { Notes.Length: > 0 } r ? r.Notes : "No release notes.";
    public string Published => Available?.PublishedAt is { } at ? "Published " + at.ToLocalTime().ToString("d", CultureInfo.CurrentCulture) : "";
    public bool CanDownload => Available?.DownloadUrl is not null;

    /// <summary>The start-up check: quiet, and only when the setting is on (aso decides) and the version is not skipped.</summary>
    public Task CheckAutomaticallyAsync() => status.QuietlyAsync(async () => Show(await client.CheckForUpdateAsync(automatic: true).ConfigureAwait(true)));

    /// <summary>Check now, from Settings: a skipped release is shown again, and the result is reported either way.</summary>
    [RelayCommand]
    private Task CheckNowAsync() => status.RunAsync("Checking GitHub for a newer release…", async () =>
    {
        var check = await client.CheckForUpdateAsync(automatic: false).ConfigureAwait(true);
        Show(check);
        status.Info(check.Available ? $"Version {check.Latest} is available; see the sidebar."
            : check.Latest is null ? $"No release is published yet; {check.Current} is current." : $"You have the latest version ({check.Current}).");
    });

    private bool CanDismiss() => Available is not null;

    /// <summary>Hides this release from automatic checks.</summary>
    [RelayCommand(CanExecute = nameof(CanDismiss))]
    private Task SkipAsync() => Available is not { } release ? Task.CompletedTask : status.RunAsync("Skipping the release…", async () =>
    {
        await client.SkipVersionAsync(release.Version).ConfigureAwait(true);
        Available = null;
        status.Info($"Version {release.Version} will not be offered again; Check for updates in Settings still shows it.");
    });

    /// <summary>Hides the banner until the next start.</summary>
    [RelayCommand(CanExecute = nameof(CanDismiss))]
    private void Later() => Available = null;

    /// <summary>Only https addresses on GitHub are opened.</summary>
    public static bool IsGitHub(string? address) =>
        Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps
        && (uri.Host == "github.com" || uri.Host.EndsWith(".github.com", StringComparison.OrdinalIgnoreCase)
            || uri.Host.EndsWith(".githubusercontent.com", StringComparison.OrdinalIgnoreCase));

    private void Show(UpdateCheck check)
    {
        Current = check.Current;
        Available = check.Available ? check.Release : null;
    }
}
