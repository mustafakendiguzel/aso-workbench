using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class UpdatesTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    // update-current.json is the real engine's answer against GitHub (1.0.0 is the latest release); update-available.json is the same
    // shape with a newer release.
    private static FakeCli Cli(string fixture) => new()
    {
        Respond = args => FakeCli.Command(args) switch
        {
            "update" when args.Contains("skip") => FakeCli.Ok("{}"),
            "update" => FakeCli.Fixture(fixture),
            _ => FakeCli.Ok("{}"),
        },
    };

    [Fact]
    public async Task TheCheckIsReadAndOnlyTheStartUpOneIsAutomatic()
    {
        var cli = Cli("update-available");
        var check = await new AsoClient(cli).CheckForUpdateAsync(automatic: true, Ct);
        Assert.Equal(["--json", "update", "check", "--automatic"], cli.Calls[^1]);
        Assert.True(check.Available);
        Assert.Equal(("1.2.0", "https://github.com/acme/aso/releases/tag/v1.2.0"), (check.Release!.Version, check.Release.PageUrl));
        Assert.EndsWith("aso-workbench-windows-x86_64.zip", check.Release.DownloadUrl, StringComparison.Ordinal);

        var current = await new AsoClient(Cli("update-current")).CheckForUpdateAsync(automatic: false, Ct);
        Assert.Equal(("1.0.0", "1.0.0", false), (current.Current, current.Latest, current.Available));
        Assert.Null(current.Release);
    }

    [Fact]
    public async Task ANewerReleaseShowsUntilSkippedOrPutOff()
    {
        var cli = Cli("update-available");
        var status = new StatusViewModel();
        var vm = new UpdatesViewModel(new AsoClient(cli), status);
        Assert.False(vm.HasUpdate);
        Assert.False(vm.SkipCommand.CanExecute(null));

        await vm.CheckAutomaticallyAsync();
        Assert.True(vm.HasUpdate);
        Assert.Equal("Version 1.2.0 is available", vm.Banner);
        Assert.Equal("ASO Workbench 1.2.0 (you have 1.0.0)", vm.Heading);
        Assert.StartsWith("### Added", vm.Notes, StringComparison.Ordinal);
        Assert.True(vm.CanDownload);

        vm.LaterCommand.Execute(null);
        Assert.False(vm.HasUpdate);

        await vm.CheckNowCommand.ExecuteAsync(null);
        Assert.Equal("Version 1.2.0 is available; see the sidebar.", status.Message);
        await vm.SkipCommand.ExecuteAsync(null);
        Assert.Equal(["--json", "update", "skip", "1.2.0"], cli.Calls[^1]);
        Assert.False(vm.HasUpdate);
        Assert.StartsWith("Version 1.2.0 will not be offered again", status.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task UpToDateIsReportedAndOnlyGitHubLinksOpen()
    {
        var status = new StatusViewModel();
        var vm = new UpdatesViewModel(new AsoClient(Cli("update-current")), status);
        await vm.CheckNowCommand.ExecuteAsync(null);
        Assert.False(vm.HasUpdate);
        Assert.Equal("You have the latest version (1.0.0).", status.Message);

        Assert.True(UpdatesViewModel.IsGitHub("https://github.com/acme/aso/releases/tag/v1.2.0"));
        Assert.True(UpdatesViewModel.IsGitHub("https://objects.githubusercontent.com/file"));
        Assert.False(UpdatesViewModel.IsGitHub("http://github.com/acme"));
        Assert.False(UpdatesViewModel.IsGitHub("https://github.com.example.com/x"));
        Assert.False(UpdatesViewModel.IsGitHub(null));
    }
}
