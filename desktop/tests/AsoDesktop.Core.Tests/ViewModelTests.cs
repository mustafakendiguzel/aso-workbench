using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class ResearchAndMetadataViewModelTests
{
    [Fact]
    public async Task SearchHintsAndDifficultyFillTheirPanels()
    {
        var cli = new FakeCli();
        cli.Respond = args => FakeCli.Fixture(FakeCli.Command(args) switch { "search" => "search", "hints" => "hints", _ => "difficulty" });
        var status = new StatusViewModel();
        var vm = new ResearchViewModel(new AsoClient(cli), status);
        Assert.False(vm.SearchCommand.CanExecute(null));

        vm.Term = " keynote ";
        await vm.SearchCommand.ExecuteAsync(null);
        await vm.HintsCommand.ExecuteAsync(null);
        await vm.DifficultyCommand.ExecuteAsync(null);

        Assert.Single(vm.Results);
        Assert.Equal(10, vm.Hints.Count);
        Assert.Equal(57, vm.Difficulty?.Score);
        Assert.Equal(["--json", "search", "--country", "US", "--device", "iphone", "--limit", "25", "--", "keynote"], cli.Calls[0]);

        vm.UseHintCommand.Execute("presentation");
        Assert.Equal("presentation", vm.Term);
    }

    [Fact]
    public void LengthsCountCodePointsLikeTheAppStore()
    {
        Assert.Equal(5, MetadataViewModel.CodePoints("Notes"));
        Assert.Equal(4, MetadataViewModel.CodePoints("Bütç"));
        Assert.Equal(2, MetadataViewModel.CodePoints("😀😀"));   // four UTF-16 units, two characters
    }

    [Fact]
    public async Task ErrorsFromTheCheckAreShownFirstAndFlagTheStatus()
    {
        var cli = new FakeCli { Respond = _ => FakeCli.Fixture("validate") with { ExitCode = 1 } };
        var status = new StatusViewModel();
        var vm = new MetadataViewModel(new AsoClient(cli), status) { Title = new string('A', 31) };
        Assert.Equal(31, vm.TitleLength);

        await vm.CheckCommand.ExecuteAsync(null);

        Assert.Equal(ValidationSeverity.Error, vm.Issues[0].Severity);
        Assert.True(status.IsError);
        Assert.StartsWith("1 error(s)", status.Message, StringComparison.Ordinal);
    }
}
