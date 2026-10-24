using System.Diagnostics;
using System.Text;

namespace AsoDesktop.Core;

/// <summary>What one run of the aso command produced.</summary>
public sealed record CliResult(int ExitCode, string Output, string Errors);

/// <summary>Runs the aso command. The process implementation is <see cref="AsoProcessCli"/>; tests use a fake.</summary>
public interface IAsoCli
{
    /// <param name="standardInput">Written to the command's stdin, then closed: how keys reach aso, never as arguments.</param>
    /// <param name="onErrorLine">Called for each stderr line as it arrives (progress), on a background thread.</param>
    Task<CliResult> RunAsync(IReadOnlyList<string> arguments, string? standardInput, Action<string>? onErrorLine, CancellationToken cancellationToken);
}

/// <summary>A failed aso run, with the command's own message.</summary>
public sealed class AsoCliException(string message, int exitCode) : Exception(message)
{
    /// <summary>1: the command failed; 64: it was called wrongly; 0: it ran but its output could not be read.</summary>
    public int ExitCode { get; } = exitCode;

    /// <summary>The first "error: " line aso wrote, else the first non-empty stderr line.</summary>
    public static AsoCliException From(CliResult result)
    {
        var lines = result.Errors.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        var message = lines.FirstOrDefault(l => l.StartsWith("error: ", StringComparison.Ordinal))?["error: ".Length..]
            ?? lines.FirstOrDefault()
            ?? $"aso exited with code {result.ExitCode}.";
        return new AsoCliException(message, result.ExitCode);
    }
}

/// <summary>Runs the aso executable as a child process, one run per command.</summary>
public sealed class AsoProcessCli(string executablePath, string? dataDirectory = null) : IAsoCli
{
    public string ExecutablePath { get; } = executablePath;

    public async Task<CliResult> RunAsync(IReadOnlyList<string> arguments, string? standardInput, Action<string>? onErrorLine,
                                         CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo(ExecutablePath)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            // No byte-order mark: it would become the first character of a key.
            StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
        };
        // Global options go first: everything after a "--" in the arguments is positional.
        if (dataDirectory is not null)
        {
            start.ArgumentList.Add("--data-dir");
            start.ArgumentList.Add(dataDirectory);
        }
        // ArgumentList quotes each argument for the platform, so keywords with spaces or quotes arrive intact.
        foreach (var argument in arguments) start.ArgumentList.Add(argument);

        using var process = Process.Start(start) ?? throw new AsoCliException($"Could not start {ExecutablePath}.", exitCode: 0);
        // Always closed, so a command that reads stdin never waits for a console.
        if (standardInput is not null)
            await process.StandardInput.WriteAsync(standardInput.AsMemory(), cancellationToken).ConfigureAwait(false);
        process.StandardInput.Close();
        var errors = new StringBuilder();
        var readErrors = Task.Run(async () =>
        {
            while (await process.StandardError.ReadLineAsync(CancellationToken.None).ConfigureAwait(false) is { } line)
            {
                lock (errors) errors.AppendLine(line);
                onErrorLine?.Invoke(line);
            }
        }, CancellationToken.None);
        var readOutput = process.StandardOutput.ReadToEndAsync(CancellationToken.None);

        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            throw;
        }
        var output = await readOutput.ConfigureAwait(false);
        await readErrors.ConfigureAwait(false);
        lock (errors) return new CliResult(process.ExitCode, output, errors.ToString());
    }
}
