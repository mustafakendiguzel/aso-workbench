using AsoDesktop.Core;

namespace AsoDesktop.Core.Tests;

/// <summary>The aso command without a process: records each call and answers from <see cref="Respond"/>.</summary>
internal sealed class FakeCli : IAsoCli
{
    public List<IReadOnlyList<string>> Calls { get; } = [];

    public Func<IReadOnlyList<string>, CliResult> Respond { get; set; } = _ => new CliResult(0, "{}", "");

    /// <summary>Stderr lines delivered before the result, as progress arrives from the real command.</summary>
    public List<string> ErrorLines { get; } = [];

    public Task<CliResult> RunAsync(IReadOnlyList<string> arguments, Action<string>? onErrorLine, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Calls.Add(arguments);
        foreach (var line in ErrorLines) onErrorLine?.Invoke(line);
        return Task.FromResult(Respond(arguments));
    }

    public static CliResult Ok(string output) => new(0, output, "");

    public static CliResult Fixture(string name) => Ok(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", name + ".json")));

    /// <summary>The command of a call without its options: "keywords list", "app add", "measure".</summary>
    public static string Command(IReadOnlyList<string> arguments)
    {
        var words = arguments.Where(a => a != "--json").TakeWhile(a => !a.StartsWith('-')).ToList();
        return words is [("app" or "keywords") and var group, var action, ..] ? $"{group} {action}" : words.FirstOrDefault() ?? "";
    }
}

/// <summary>Reports synchronously, so tests see every step before the call returns.</summary>
internal sealed class ImmediateProgress<T> : IProgress<T>
{
    public List<T> Reports { get; } = [];
    public void Report(T value) => Reports.Add(value);
}
