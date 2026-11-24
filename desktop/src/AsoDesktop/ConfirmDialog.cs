using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace AsoDesktop;

/// <summary>A yes/no question for actions that cannot be undone; closes with true only when confirmed.</summary>
public sealed class ConfirmDialog : Window
{
    public ConfirmDialog(string title, string message, string confirm)
    {
        Title = title;
        Width = 440;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var yes = new Button { Content = confirm, Classes = { "accent" } };
        var no = new Button { Content = "Cancel", IsCancel = true, IsDefault = true };
        yes.Click += (_, _) => Close(true);
        no.Click += (_, _) => Close(false);
        Content = new StackPanel
        {
            Margin = new Thickness(20),
            Spacing = 16,
            Children =
            {
                new TextBlock { Text = message, TextWrapping = Avalonia.Media.TextWrapping.Wrap },
                new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8, Children = { no, yes } },
            },
        };
    }

    public static async Task<bool> AskAsync(Window owner, string title, string message, string confirm) =>
        await new ConfirmDialog(title, message, confirm).ShowDialog<bool?>(owner) == true;
}
