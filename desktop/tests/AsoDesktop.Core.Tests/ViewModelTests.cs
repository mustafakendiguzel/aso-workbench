using AsoDesktop.Core;
using AsoDesktop.Core.ViewModels;

namespace AsoDesktop.Core.Tests;

public sealed class ResearchViewModelTests
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
}
