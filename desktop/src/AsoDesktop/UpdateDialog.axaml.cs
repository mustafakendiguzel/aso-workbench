using AsoDesktop.Core.ViewModels;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace AsoDesktop;

/// <summary>A newer release: its notes, the release page and this platform's download open in the browser (GitHub addresses only).</summary>
public sealed partial class UpdateDialog : Window
{
    public UpdateDialog() => InitializeComponent();

    public UpdateDialog(UpdatesViewModel viewModel) : this() => DataContext = viewModel;

    private UpdatesViewModel? ViewModel => DataContext as UpdatesViewModel;

    private async void OpenReleasePage(object? sender, RoutedEventArgs e) => await OpenAsync(ViewModel?.Available?.PageUrl);

    private async void Download(object? sender, RoutedEventArgs e) => await OpenAsync(ViewModel?.Available?.DownloadUrl);

    private async Task OpenAsync(string? address)
    {
        if (UpdatesViewModel.IsGitHub(address) && Uri.TryCreate(address, UriKind.Absolute, out var uri)) await Launcher.LaunchUriAsync(uri);
    }

    private async void Skip(object? sender, RoutedEventArgs e)
    {
        if (ViewModel is { } vm) await vm.SkipCommand.ExecuteAsync(null);
        Close();
    }

    private void Later(object? sender, RoutedEventArgs e)
    {
        ViewModel?.LaterCommand.Execute(null);
        Close();
    }
}
