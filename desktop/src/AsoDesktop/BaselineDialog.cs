using Avalonia;
using Avalonia.Controls;
using Avalonia.Data;
using Avalonia.Layout;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop;

/// <summary>Takes what is live on the App Store today for one locale, typed or pasted; closes with true when it should be saved.</summary>
public sealed class BaselineDialog : Window
{
    public BaselineDialog(string locale, IReadOnlyList<MetadataFieldViewModel> fields)
    {
        Title = $"Current listing · {locale}";
        Width = 600;
        Height = 640;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var form = new StackPanel { Spacing = 4, Margin = new Thickness(0, 0, 18, 0) };
        form.Children.Add(new TextBlock
        {
            Text = "Paste what is live on the App Store today. The draft is compared against it; nothing is sent to Apple.",
            TextWrapping = Avalonia.Media.TextWrapping.Wrap,
            Opacity = 0.65,
            Margin = new Thickness(0, 0, 0, 8),
        });
        foreach (var field in fields)
        {
            form.Children.Add(new TextBlock { Text = field.Title, FontWeight = Avalonia.Media.FontWeight.SemiBold, Margin = new Thickness(0, 6, 0, 0) });
            var box = new TextBox
            {
                DataContext = field,
                AcceptsReturn = field.IsMultiline,
                TextWrapping = Avalonia.Media.TextWrapping.Wrap,
                MinHeight = field.MinHeight,
                MaxHeight = field.IsMultiline ? 200 : double.PositiveInfinity,
            };
            box.Bind(TextBox.TextProperty, new Binding(nameof(MetadataFieldViewModel.Text)) { Mode = BindingMode.TwoWay });
            form.Children.Add(box);
        }

        var save = new Button { Content = "Save baseline", Classes = { "accent" }, IsDefault = true };
        var cancel = new Button { Content = "Cancel", IsCancel = true };
        save.Click += (_, _) => Close(true);
        cancel.Click += (_, _) => Close(false);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8, Children = { cancel, save } };
        DockPanel.SetDock(buttons, Dock.Bottom);
        Content = new DockPanel
        {
            Margin = new Thickness(20),
            Children = { buttons, new ScrollViewer { Content = form, Margin = new Thickness(0, 0, 0, 12) } },
        };
    }
}
