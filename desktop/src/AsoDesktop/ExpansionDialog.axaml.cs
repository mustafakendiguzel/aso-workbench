using AsoDesktop.Core.ViewModels;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace AsoDesktop;

/// <summary>The keywords tried in other storefronts; closing stops a run that is still going.</summary>
public sealed partial class ExpansionDialog : Window
{
    public ExpansionDialog() => InitializeComponent();

    public ExpansionDialog(ExpansionViewModel viewModel) : this() => DataContext = viewModel;

    private void CloseDialog(object? sender, RoutedEventArgs e)
    {
        (DataContext as ExpansionViewModel)?.RunCancelCommand.Execute(null);
        Close();
    }
}
