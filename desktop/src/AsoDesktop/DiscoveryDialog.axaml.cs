using System.ComponentModel;
using AsoDesktop.Core.ViewModels;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace AsoDesktop;

/// <summary>Closes with true when keywords were added, false when closed without adding.</summary>
public sealed partial class DiscoveryDialog : Window
{
    public DiscoveryDialog() => InitializeComponent();

    public DiscoveryDialog(DiscoveryViewModel viewModel) : this()
    {
        DataContext = viewModel;
        viewModel.PropertyChanged += OnViewModelChanged;
    }

    private DiscoveryViewModel? ViewModel => DataContext as DiscoveryViewModel;

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(DiscoveryViewModel.Added) && ViewModel is { Added: not null }) Close(true);
    }

    private void CandidateSelectionChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (ViewModel is { } vm && sender is DataGrid grid) vm.SelectedRows = grid.SelectedItems.OfType<DiscoveryLine>().ToList();
    }

    private void SelectGolden(object? sender, RoutedEventArgs e)
    {
        if (ViewModel is not { } vm) return;
        CandidatesGrid.SelectedItems.Clear();
        foreach (var row in vm.GoldenRows) CandidatesGrid.SelectedItems.Add(row);
    }

    private void Cancel(object? sender, RoutedEventArgs e)
    {
        ViewModel?.FindCancelCommand.Execute(null);
        Close(false);
    }
}
