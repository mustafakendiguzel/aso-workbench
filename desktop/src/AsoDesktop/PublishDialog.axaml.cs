using AsoDesktop.Core.ViewModels;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace AsoDesktop;

/// <summary>The confirm step before writing to App Store Connect, and the results afterwards.</summary>
public sealed partial class PublishDialog : Window
{
    public PublishDialog() => InitializeComponent();

    public PublishDialog(PublishViewModel viewModel) : this() => DataContext = viewModel;

    private void CloseDialog(object? sender, RoutedEventArgs e) => Close();
}
