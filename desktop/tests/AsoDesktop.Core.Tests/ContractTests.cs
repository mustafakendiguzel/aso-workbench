using AsoDesktop.Core;

namespace AsoDesktop.Core.Tests;

/// <summary>Parses output captured from the real engine (Fixtures/*.json), so a change to aso's JSON shows up here.</summary>
public sealed class ContractTests
{
    private static AsoClient ClientAnswering(string fixture) => new(new FakeCli { Respond = _ => FakeCli.Fixture(fixture) });

    [Fact]
    public async Task VersionIsRead()
    {
        Assert.Equal("1.0.0", await ClientAnswering("version").VersionAsync(ct: TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task AppsAreRead()
    {
        var app = Assert.Single(await ClientAnswering("app-list").ListAppsAsync(ct: TestContext.Current.CancellationToken));
        Assert.Equal(361285480, app.TrackId);
        Assert.Equal("com.apple.Keynote", app.BundleId);
        Assert.Equal("Apple Inc.", app.SellerName);
        Assert.StartsWith("https://", app.IconUrl, StringComparison.Ordinal);
        Assert.Equal(TimeSpan.Zero, app.CreatedAt.Offset);
    }

    [Fact]
    public async Task KeywordRowsKeepAbsentValuesAbsent()
    {
        var rows = await ClientAnswering("keywords-list").ListKeywordsAsync(361285480, ct: TestContext.Current.CancellationToken);
        Assert.Equal(2, rows.Count);

        var found = rows[0];
        Assert.Equal(("presentation", "found", 3, "#3"), (found.Keyword, found.Status, found.Rank, found.RankLabel));
        Assert.Equal(57, found.Difficulty);
        Assert.NotNull(found.MeasuredAt);

        var outside = rows[1];
        Assert.Equal("outside", outside.Status);
        Assert.Null(outside.Rank);                 // not in the results is not a rank
        Assert.Equal("> 179", outside.RankLabel);
        Assert.Equal(179, outside.ObservedCount);
        Assert.True(outside.BrandLike);
        Assert.Null(outside.Popularity);           // no popularity source: absent, never guessed
        Assert.Null(outside.Delta);
    }

    [Fact]
    public async Task AddedKeywordsAndMeasureSummaryAreRead()
    {
        var added = await ClientAnswering("keywords-add").AddKeywordsAsync(1, ["presentation", "slides maker"], "US", "iphone", ct: TestContext.Current.CancellationToken);
        Assert.Equal("US · iphone", added.Market);
        Assert.Equal(["presentation", "slides maker"], added.Added);
        Assert.Empty(added.AlreadyTracked);

        Assert.Equal(new MeasureSummary(2, 1, 1, 0), await ClientAnswering("measure").MeasureAsync(1, ct: TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task SearchHintsAndValidationAreRead()
    {
        var result = Assert.Single(await ClientAnswering("search").SearchAsync("keynote", "US", ct: TestContext.Current.CancellationToken));
        Assert.Equal("Keynote: Design Presentations", result.Name);
        Assert.True(result.RatingCount > 0);

        Assert.Contains("presentation", await ClientAnswering("hints").HintsAsync("pres", "US", ct: TestContext.Current.CancellationToken));

        var issues = await new AsoClient(new FakeCli { Respond = _ => FakeCli.Fixture("validate") with { ExitCode = 1 } })
            .ValidateAsync(new string('A', 31), "", "notes, notes", ct: TestContext.Current.CancellationToken);
        Assert.Equal([ValidationSeverity.Error, ValidationSeverity.Warning, ValidationSeverity.Info], issues.Select(i => i.Severity));
        Assert.Equal("name", issues[0].Field);
    }

    [Fact]
    public async Task DifficultyComponentsAreRead()
    {
        var report = await ClientAnswering("difficulty").DifficultyAsync("presentation", "US", ct: TestContext.Current.CancellationToken);
        Assert.Equal(57, report.Score);
        Assert.Equal(10, report.SampleSize);
        Assert.False(string.IsNullOrWhiteSpace(report.Tier));
        Assert.Equal(7, report.Components.Count);
        Assert.Equal("35%", report.Components[0].Weight);
        Assert.All(report.Components, c => Assert.False(string.IsNullOrWhiteSpace(c.Explanation)));
    }
}
