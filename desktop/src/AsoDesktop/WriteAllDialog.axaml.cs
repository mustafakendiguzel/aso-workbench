using AsoDesktop.Core.ViewModels;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace AsoDesktop;

/// <summary>Writes the chosen locales one after another and lists what was saved.</summary>
public sealed partial class WriteAllDialog : Window
{
    public WriteAllDialog() => InitializeComponent();

    public WriteAllDialog(WriteAllViewModel viewModel) : this() => DataContext = viewModel;

    private void CloseDialog(object? sender, RoutedEventArgs e) => Close();
}
