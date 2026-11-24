using System.Globalization;
using AsoDesktop.Core.ViewModels;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace AsoDesktop;

/// <summary>
/// The macOS inspector's rank chart: rank on a reversed log scale (#1 at the top), a line through the measurements that
/// found the app, a dashed "not in the top N" line with a cross for each measurement that did not, and the best rank
/// highlighted. Failed requests are not points: they leave gaps.
/// </summary>
public sealed class RankChart : Control
{
    public static readonly StyledProperty<IReadOnlyList<RankChartPoint>?> PointsProperty =
        AvaloniaProperty.Register<RankChart, IReadOnlyList<RankChartPoint>?>(nameof(Points));

    static RankChart() => AffectsRender<RankChart>(PointsProperty);

    public IReadOnlyList<RankChartPoint>? Points
    {
        get => GetValue(PointsProperty);
        set => SetValue(PointsProperty, value);
    }

    private static readonly int[] GridRanks = [1, 10, 50, 100, 200];
    private static readonly IBrush Line = new SolidColorBrush(Color.FromRgb(0x2F, 0x7D, 0xE1));
    private static readonly IBrush Best = new SolidColorBrush(Color.FromRgb(0x2E, 0x9E, 0x4F));
    private static readonly IBrush Outside = new SolidColorBrush(Color.FromRgb(0xD1, 0x34, 0x38));

    public override void Render(DrawingContext context)
    {
        var points = Points ?? [];
        var bounds = new Rect(Bounds.Size);
        var text = this.FindResource("SystemControlForegroundBaseHighBrush") as IBrush ?? Brushes.Gray;
        var grid = new Pen(new SolidColorBrush(Colors.Gray, 0.25), 1);
        var plot = new Rect(bounds.X + 40, bounds.Y + 8, Math.Max(0, bounds.Width - 52), Math.Max(0, bounds.Height - 30));

        if (points.Count == 0)
        {
            Label(context, "No measurements in this range", plot.Center, text, center: true);
            return;
        }

        // Depth of the y axis: the deepest search observed, so "not in the top N" sits on the bottom line.
        var depth = Math.Max(10, points.Max(p => p.ObservedCount));
        double Y(int rank) => plot.Top + Math.Log(Math.Max(1, rank)) / Math.Log(depth + 1) * plot.Height;
        var first = points[0].At;
        var span = Math.Max(1, (points[^1].At - first).TotalSeconds);
        double X(DateTimeOffset at) => points.Count == 1 ? plot.Center.X : plot.Left + (at - first).TotalSeconds / span * plot.Width;

        foreach (var rank in GridRanks.Where(r => r <= depth))
        {
            var y = Y(rank);
            context.DrawLine(grid, new Point(plot.Left, y), new Point(plot.Right, y));
            Label(context, $"#{rank}", new Point(bounds.Left + 2, y - 7), text);
        }
        var bottom = plot.Top + plot.Height;
        context.DrawLine(new Pen(Outside, 1, dashStyle: DashStyle.Dash), new Point(plot.Left, bottom), new Point(plot.Right, bottom));
        Label(context, $"not in top {depth}", new Point(plot.Right - 90, bottom + 2), text);

        var found = points.Where(p => p.Rank is not null).ToList();
        var pen = new Pen(Line, 2);
        for (var i = 1; i < found.Count; i++)
            context.DrawLine(pen, new Point(X(found[i - 1].At), Y(found[i - 1].Rank!.Value)), new Point(X(found[i].At), Y(found[i].Rank!.Value)));
        var best = found.Count == 0 ? (int?)null : found.Min(p => p.Rank);
        foreach (var p in found)
            context.DrawEllipse(p.Rank == best ? Best : Line, null, new Point(X(p.At), Y(p.Rank!.Value)), p.Rank == best ? 4.5 : 3, p.Rank == best ? 4.5 : 3);

        var cross = new Pen(Outside, 1.5);
        foreach (var p in points.Where(p => p.Rank is null))
        {
            var c = new Point(X(p.At), bottom);
            context.DrawLine(cross, c + new Point(-4, -4), c + new Point(4, 4));
            context.DrawLine(cross, c + new Point(-4, 4), c + new Point(4, -4));
        }

        Label(context, first.ToLocalTime().ToString("d", CultureInfo.CurrentCulture), new Point(plot.Left, bottom + 12), text);
        if (points.Count > 1)
            Label(context, points[^1].At.ToLocalTime().ToString("d", CultureInfo.CurrentCulture), new Point(plot.Right - 70, bottom + 12), text);
    }

    private static void Label(DrawingContext context, string value, Point at, IBrush brush, bool center = false)
    {
        var formatted = new FormattedText(value, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Typeface.Default, 11, brush);
        context.DrawText(formatted, center ? new Point(at.X - formatted.Width / 2, at.Y - formatted.Height / 2) : at);
    }
}
