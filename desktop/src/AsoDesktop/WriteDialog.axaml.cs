using System.ComponentModel;
using AsoDesktop.Core.ViewModels;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace AsoDesktop;

/// <summary>Three proposals for one locale; closes once one is used as the draft.</summary>
public sealed partial class WriteDialog : Window
{
    public WriteDialog() => InitializeComponent();

    public WriteDialog(WriteViewModel viewModel) : this()
    {
        DataContext = viewModel;
        viewModel.PropertyChanged += OnViewModelChanged;
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(WriteViewModel.Used) && DataContext is WriteViewModel { Used: true }) Close();
    }

    private void CloseDialog(object? sender, RoutedEventArgs e) => Close();
}
