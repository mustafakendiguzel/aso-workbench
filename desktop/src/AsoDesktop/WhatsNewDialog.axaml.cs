using AsoDesktop.Core.ViewModels;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace AsoDesktop;

/// <summary>Release notes written once and translated into the chosen locales.</summary>
public sealed partial class WhatsNewDialog : Window
{
    public WhatsNewDialog() => InitializeComponent();

    public WhatsNewDialog(WhatsNewViewModel viewModel) : this() => DataContext = viewModel;

    private void CloseDialog(object? sender, RoutedEventArgs e) => Close();
}
