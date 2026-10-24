using AsoDesktop.Core.ViewModels;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Platform.Storage;

namespace AsoDesktop;

public sealed partial class MainWindow : Window
{
    public MainWindow() => InitializeComponent();

    private MainViewModel? ViewModel => DataContext as MainViewModel;

    /// <summary>Without the engine there is nothing to drive: say where it is looked for instead of showing empty screens.</summary>
    public void ShowMissingEngine(string executableName) => Content = new TextBlock
    {
        Margin = new Avalonia.Thickness(32),
        MaxWidth = 560,
        TextWrapping = Avalonia.Media.TextWrapping.Wrap,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Text = $"The ASO Workbench engine ({executableName}) was not found.\n\n"
             + $"Put {executableName} next to this app, add its folder to PATH, or set ASO_CLI to its full path, then start the app again.",
    };

    // Links in the connection guides open in the default browser; only web links are opened.
    private async void OpenLink(object? sender, RoutedEventArgs e)
    {
        if (sender is Control { Tag: string link } && Uri.TryCreate(link, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps)
            await Launcher.LaunchUriAsync(uri);
    }

    private async void OpenDataFolder(object? sender, RoutedEventArgs e)
    {
        if (ViewModel?.DataDirectory is { } folder && Directory.Exists(folder))
            await Launcher.LaunchDirectoryInfoAsync(new DirectoryInfo(folder));
    }

    /// <summary>The key file's path goes to aso, which reads the key itself; the window never holds the key.</summary>
    private async void ChooseKeyFile(object? sender, RoutedEventArgs e)
    {
        if (ViewModel is not { } vm || sender is not Control { Tag: string target }) return;
        var (title, pattern) = target == "AppleAds" ? ("Apple Ads private key", "*.pem") : ("App Store Connect key", "*.p8");
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = title,
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType(title) { Patterns = [pattern] }, FilePickerFileTypes.All],
        });
        if (files.Count == 0 || files[0].TryGetLocalPath() is not { } path) return;
        if (target == "AppleAds") vm.Settings.AppleAds.KeyFilePath = path;
        else vm.Settings.AppStoreConnect.KeyFilePath = path;
    }
}
