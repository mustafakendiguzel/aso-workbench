namespace AsoDesktop.Core;

/// <summary>Finds the aso executable the window drives.</summary>
public static class AsoLocator
{
    public static string ExecutableName(bool isWindows) => isWindows ? "aso.exe" : "aso";

    /// <summary>
    /// In order: <c>ASO_CLI</c>, aso next to the app (how packages ship it), then each folder on <c>PATH</c>.
    /// Returns null when none exists.
    /// </summary>
    public static string? Find(Func<string, string?> environment, string appDirectory, bool isWindows, Func<string, bool> fileExists)
    {
        if (environment("ASO_CLI") is { Length: > 0 } configured)
            return fileExists(configured) ? configured : null;

        var name = ExecutableName(isWindows);
        var bundled = Path.Combine(appDirectory, name);
        if (fileExists(bundled)) return bundled;

        var separator = isWindows ? ';' : ':';
        foreach (var folder in (environment("PATH") ?? "").Split(separator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var candidate = Path.Combine(folder, name);
            if (fileExists(candidate)) return candidate;
        }
        return null;
    }

    public static string? Find() =>
        Find(Environment.GetEnvironmentVariable, AppContext.BaseDirectory, OperatingSystem.IsWindows(), File.Exists);
}
