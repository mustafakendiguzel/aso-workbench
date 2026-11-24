using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class EstimateTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    // keywords-estimates.json is the engine with the bundled popularity models: "notes" on Apple's list, "habit tracker" and "zqxv" off it and
    // estimated by the model (below the range, with its 6–29 rank).
    private static async Task<IReadOnlyList<KeywordReportRow>> RowsAsync() =>
        await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("keywords-estimates") }).ListKeywordsAsync(1, ct: Ct);

    [Fact]
    public async Task EstimatesShowAsApproximateAndExplainThemselves()
    {
        var rows = (await RowsAsync()).ToDictionary(r => r.Keyword);
        Assert.Equal("62", rows["notes"].PopularityLabel);
        Assert.False(rows["notes"].IsEstimate);

        var habit = rows["habit tracker"];
        Assert.True(habit.IsEstimate);
        Assert.Null(habit.Popularity);
        Assert.Equal(8, habit.PopularitySubFloor);
        Assert.Equal("~8", habit.PopularityLabel);
        Assert.InRange(habit.PopularityProbability ?? -1, 0, 1);
        var text = InspectorViewModel.Popularity(habit);
        Assert.StartsWith("~8: below Apple's published range under 31; the model ranks its demand 8 on the 6–29 band", text, StringComparison.Ordinal);

        var published = habit with { Popularity = 30, PopularitySubFloor = null, PopularityProbability = 0.8 };
        Assert.Equal("~30", published.PopularityLabel);
        Assert.StartsWith("~30 of 100, the model's estimate from public signals", InspectorViewModel.Popularity(published), StringComparison.Ordinal);
        var bare = habit with { PopularitySubFloor = null };
        Assert.Equal("< 31", bare.PopularityLabel);
    }

    [Fact]
    public async Task EstimatesSortBetweenScoresAndTermsBelowTheRange()
    {
        var rows = await RowsAsync();
        var lines = rows.Select(r => new KeywordRow(r)).ToList();
        var notes = lines.Single(l => l.Keyword == "notes");
        var habit = lines.Single(l => l.Keyword == "habit tracker");
        var plain = new KeywordRow(habit.Report with { PopularitySource = "belowRange", PopularitySubFloor = null });
        Assert.True(notes.PopularityOrder > habit.PopularityOrder);
        Assert.True(habit.PopularityOrder > plain.PopularityOrder);
    }
}
