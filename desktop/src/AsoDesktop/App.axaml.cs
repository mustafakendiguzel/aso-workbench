using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace AsoDesktop;

public sealed partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var window = new MainWindow();
            if (AsoLocator.Find() is { } executable)
            {
                var viewModel = new MainViewModel(new AsoClient(new AsoProcessCli(executable)));
                window.DataContext = viewModel;
                viewModel.LoadCommand.Execute(null);
            }
            else
            {
                window.ShowMissingEngine(AsoLocator.ExecutableName(OperatingSystem.IsWindows()));
            }
            desktop.MainWindow = window;
        }
        base.OnFrameworkInitializationCompleted();
    }
}
