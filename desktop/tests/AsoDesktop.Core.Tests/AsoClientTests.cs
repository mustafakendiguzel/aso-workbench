using AsoDesktop.Core;

namespace AsoDesktop.Core.Tests;

public sealed class AsoClientTests
{
    [Fact]
    public async Task GlobalOptionsComeFirstAndKeywordsFollowDoubleDash()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("keywords-add") };
        await new AsoClient(cli).AddKeywordsAsync(42, ["-dash", "two words"], "TR", "ipad", ct: TestContext.Current.CancellationToken);
        Assert.Equal(["--json", "keywords", "add", "42", "--country", "TR", "--device", "ipad", "--", "-dash", "two words"], cli.Calls.Single());
    }

    [Fact]
    public async Task OptionalFiltersAreLeftOutWhenEmpty()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Ok("[]") };
        var client = new AsoClient(cli);
        await client.ListKeywordsAsync(7, ct: TestContext.Current.CancellationToken);
        await client.ListKeywordsAsync(7, country: "DE", device: "iphone", delta: "week", ct: TestContext.Current.CancellationToken);
        Assert.Equal(["--json", "keywords", "list", "7", "--delta", "previous"], cli.Calls[0]);
        Assert.Equal(["--json", "keywords", "list", "7", "--country", "DE", "--device", "iphone", "--delta", "week"], cli.Calls[1]);
    }

    [Fact]
    public async Task FailuresCarryTheEngineMessageAndExitCode()
    {
        var cli = new FakeCli { Respond = _ => new CliResult(1, "", "error: App 42 is not tracked. Add it first.\n") };
        var error = await Assert.ThrowsAsync<AsoCliException>(() => new AsoClient(cli).ListKeywordsAsync(42, ct: TestContext.Current.CancellationToken));
        Assert.Equal("App 42 is not tracked. Add it first.", error.Message);
        Assert.Equal(1, error.ExitCode);
    }

    [Fact]
    public async Task UsageErrorsShowTheirFirstLineNotTheWholeUsage()
    {
        var cli = new FakeCli { Respond = _ => new CliResult(64, "", "error: Missing --country.\n\nUsage: aso <command> [options]\n…") };
        var error = await Assert.ThrowsAsync<AsoCliException>(() => new AsoClient(cli).HintsAsync("x", "", ct: TestContext.Current.CancellationToken));
        Assert.Equal("Missing --country.", error.Message);
        Assert.Equal(64, error.ExitCode);
    }

    [Fact]
    public async Task UnreadableOutputIsAnErrorNotAnEmptyResult()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Ok("not json") };
        var error = await Assert.ThrowsAsync<AsoCliException>(() => new AsoClient(cli).ListAppsAsync(ct: TestContext.Current.CancellationToken));
        Assert.Contains("cannot read", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ValidationErrorsStillReturnTheIssues()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("validate") with { ExitCode = 1 } };
        var issues = await new AsoClient(cli).ValidateAsync("-title", "", "", ct: TestContext.Current.CancellationToken);
        Assert.Equal(3, issues.Count);
        Assert.Equal(["--json", "validate", "--title", "-title", "--subtitle", "", "--keywords", ""], cli.Calls.Single());
        await Assert.ThrowsAsync<AsoCliException>(() =>
            new AsoClient(new FakeCli { Respond = _ => new CliResult(64, "", "error: Unknown option") }).ValidateAsync("", "", "", ct: TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task MeasureReportsEachJsonProgressLineAndIgnoresOtherStderr()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("measure") };
        cli.ErrorLines.AddRange([
            """{"completed":1,"keyword":"presentation","market":"US · iphone","outcome":"#3","status":"found","total":2}""",
            "warning: something unrelated",
            """{"completed":2,"keyword":"slides maker","market":"US · iphone","outcome":"> 179","status":"outside","total":2}""",
        ]);
        var progress = new ImmediateProgress<MeasureStep>();
        var summary = await new AsoClient(cli).MeasureAsync(1, progress: progress, ct: TestContext.Current.CancellationToken);
        Assert.Equal(2, summary.Measured);
        Assert.Equal([new MeasureStep(1, 2, "US · iphone", "presentation", "#3", "found"),
                      new MeasureStep(2, 2, "US · iphone", "slides maker", "> 179", "outside")], progress.Reports);
    }

    [Fact]
    public void StepParsingToleratesNoise()
    {
        Assert.Null(AsoClient.ParseStep("[1/2] US · iphone  notes  #2"));
        Assert.Null(AsoClient.ParseStep("{broken"));
        Assert.NotNull(AsoClient.ParseStep("""{"completed":1,"total":1,"market":"m","keyword":"k","outcome":"#1","status":"found"}"""));
    }
}

public sealed class AsoLocatorTests
{
    private static Func<string, string?> Env(Dictionary<string, string> values) => name => values.GetValueOrDefault(name);

    [Fact]
    public void ConfiguredPathWinsAndMustExist()
    {
        var exists = new HashSet<string> { "/opt/aso", "/app/aso" };
        Assert.Equal("/opt/aso", AsoLocator.Find(Env(new() { ["ASO_CLI"] = "/opt/aso" }), "/app", isWindows: false, exists.Contains));
        Assert.Null(AsoLocator.Find(Env(new() { ["ASO_CLI"] = "/missing/aso" }), "/app", isWindows: false, exists.Contains));
    }

    [Fact]
    public void BundledCopyComesBeforePath()
    {
        var bundled = Path.Combine("app", "aso");
        var onPath = Path.Combine("bin", "aso");
        var exists = new HashSet<string> { bundled, onPath };
        Assert.Equal(bundled, AsoLocator.Find(Env(new() { ["PATH"] = "bin" }), "app", isWindows: false, exists.Contains));
        Assert.Equal(onPath, AsoLocator.Find(Env(new() { ["PATH"] = "bin" }), "elsewhere", isWindows: false, exists.Contains));
    }

    [Fact]
    public void WindowsLooksForTheExeAlongSemicolonSeparatedPath()
    {
        var second = Path.Combine("tools", "aso.exe");
        var exists = new HashSet<string> { second };
        Assert.Equal(second, AsoLocator.Find(Env(new() { ["PATH"] = "first; tools" }), "app", isWindows: true, exists.Contains));
        Assert.Null(AsoLocator.Find(Env(new() { ["PATH"] = "first;tools" }), "app", isWindows: false, exists.Contains));
        Assert.Equal("aso.exe", AsoLocator.ExecutableName(isWindows: true));
    }
}

/// <summary>The real process runner against the platform's shell: arguments, stdout, stderr lines and exit code.</summary>
public sealed class AsoProcessCliTests
{
    [Fact]
    public async Task RunsAProcessAndStreamsStderrLines()
    {
        var (shell, arguments) = OperatingSystem.IsWindows()
            ? ("cmd.exe", new[] { "/c", "echo out& echo err one 1>&2& echo err two 1>&2& exit /b 3" })
            : ("/bin/sh", new[] { "-c", "echo out; echo 'err one' 1>&2; echo 'err two' 1>&2; exit 3" });
        var lines = new List<string>();
        var result = await new AsoProcessCli(shell).RunAsync(arguments, line => { lock (lines) lines.Add(line.Trim()); }, TestContext.Current.CancellationToken);
        Assert.Equal(3, result.ExitCode);
        Assert.Equal("out", result.Output.Trim());
        Assert.Equal(["err one", "err two"], lines);
        Assert.Contains("err two", result.Errors, StringComparison.Ordinal);
    }
}
