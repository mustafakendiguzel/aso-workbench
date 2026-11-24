using System.ComponentModel;
using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace AsoDesktop;

/// <summary>Closes with the added app, or with null when cancelled.</summary>
public sealed partial class AddAppDialog : Window
{
    public AddAppDialog() => InitializeComponent();

    public AddAppDialog(AddAppViewModel viewModel) : this()
    {
        DataContext = viewModel;
        viewModel.PropertyChanged += OnViewModelChanged;
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AddAppViewModel.Added) && sender is AddAppViewModel { Added: AppRecord app }) Close(app);
    }

    private void Cancel(object? sender, RoutedEventArgs e) => Close(null);
}
