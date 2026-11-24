using Avalonia.Controls;
using Avalonia.Layout;

namespace AsoDesktop;

public sealed partial class MainWindow : Window
{
    public MainWindow() => InitializeComponent();

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
}
