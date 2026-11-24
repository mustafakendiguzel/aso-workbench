using System.Globalization;
using AsoDesktop.Core.ViewModels;
using Avalonia.Data.Converters;
using Avalonia.Media;

namespace AsoDesktop;

/// <summary>Small display converters used by the XAML.</summary>
public static class Converters
{
    /// <summary>Bold for true (the tracked app among the top results), normal otherwise.</summary>
    public static readonly IValueConverter BoldWhen =
        new FuncValueConverter<bool, FontWeight>(on => on ? FontWeight.Bold : FontWeight.Normal);

    /// <summary>A point in time in the user's time zone and culture.</summary>
    public static readonly IValueConverter LocalTime =
        new FuncValueConverter<DateTimeOffset, string>(at => InspectorViewModel.When(at));
}
