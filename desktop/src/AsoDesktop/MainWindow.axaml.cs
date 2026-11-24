using AsoDesktop.Core.ViewModels;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Input.Platform;
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

    // MARK: Keywords table

    private void KeywordSelectionChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (ViewModel is { } vm && sender is DataGrid grid) vm.Keywords.SelectedRows = grid.SelectedItems.OfType<KeywordRow>().ToList();
    }

    private async void KeywordsKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.C && e.KeyModifiers.HasFlag(KeyModifiers.Control))
        {
            e.Handled = true;
            await CopySelectedKeywordsAsync();
        }
        else if (e.Key == Key.Delete)
        {
            e.Handled = true;
            await RemoveSelectedKeywordsAsync();
        }
    }

    private async void CopyKeywords(object? sender, RoutedEventArgs e) => await CopySelectedKeywordsAsync();

    private async void ConfirmRemoveSelected(object? sender, RoutedEventArgs e) => await RemoveSelectedKeywordsAsync();

    private async Task CopySelectedKeywordsAsync()
    {
        if (ViewModel is { Keywords.SelectedRows.Count: > 0 } vm && Clipboard is { } clipboard)
            await clipboard.SetTextAsync(vm.Keywords.SelectedKeywordsText);
    }

    /// <summary>Removal deletes measurements too, so it always asks first, naming what goes.</summary>
    private async Task RemoveSelectedKeywordsAsync()
    {
        if (ViewModel is not { Keywords: { SelectedRows.Count: > 0 } keywords }) return;
        var names = string.Join(", ", keywords.SelectedRows.Take(8).Select(r => r.Keyword)) + (keywords.SelectedRows.Count > 8 ? ", …" : "");
        if (await ConfirmDialog.AskAsync(this, "Remove keywords",
                $"Remove {keywords.SelectedRows.Count} keyword(s) with their measurements from {keywords.Market?.Title}? {names}. This cannot be undone.",
                "Remove"))
            await keywords.RemoveSelectedCommand.ExecuteAsync(null);
    }

    private async void ExportCsv(object? sender, RoutedEventArgs e)
    {
        if (ViewModel is not { Keywords: { Market: not null } keywords }) return;
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Export keywords",
            SuggestedFileName = keywords.ExportFileName,
            DefaultExtension = "csv",
            FileTypeChoices = [new FilePickerFileType("CSV") { Patterns = ["*.csv"] }],
        });
        if (file is null || await keywords.ExportCsvAsync() is not { } csv) return;
        await using var stream = await file.OpenWriteAsync();
        await using var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        await writer.WriteAsync(csv);
    }

    private async void ShowAddApp(object? sender, RoutedEventArgs e)
    {
        if (ViewModel is not { } vm) return;
        if (await new AddAppDialog(vm.CreateAddApp()).ShowDialog<Core.AppRecord?>(this) is { } app) await vm.AppAddedAsync(app);
    }

    private async void ShowDiscovery(object? sender, RoutedEventArgs e) => await ShowDiscoveryAsync(null);

    private async void ShowImport(object? sender, RoutedEventArgs e) => await ShowDiscoveryAsync(ViewModel?.Competitors.Selected?.App);

    private async Task ShowDiscoveryAsync(Core.Competitor? competitor)
    {
        if (ViewModel is not { } vm || vm.CreateDiscovery(competitor) is not { } discovery) return;
        if (await new DiscoveryDialog(discovery).ShowDialog<bool>(this)) await vm.DiscoveryAddedAsync();
    }

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
