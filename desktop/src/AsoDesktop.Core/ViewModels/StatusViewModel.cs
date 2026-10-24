using CommunityToolkit.Mvvm.ComponentModel;

namespace AsoDesktop.Core.ViewModels;

/// <summary>The one status line every screen reports to: what is running, what went wrong.</summary>
public sealed partial class StatusViewModel : ObservableObject
{
    [ObservableProperty]
    public partial string? Message { get; set; }

    [ObservableProperty]
    public partial bool IsError { get; set; }

    [ObservableProperty]
    public partial bool IsBusy { get; set; }

    public void Info(string message)
    {
        Message = message;
        IsError = false;
    }

    public void Error(string message)
    {
        Message = message;
        IsError = true;
    }

    /// <summary>A background load that follows a selection: no busy message, only a failure is reported.</summary>
    public async Task QuietlyAsync(Func<Task> job)
    {
        try
        {
            await job().ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
        }
        catch (AsoCliException error)
        {
            Error(error.Message);
        }
    }

    /// <summary>Runs one job: busy while it runs; aso's own message on failure; "Stopped." when cancelled.</summary>
    public async Task RunAsync(string busyMessage, Func<Task> job)
    {
        IsBusy = true;
        Info(busyMessage);
        try
        {
            await job().ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            Info("Stopped.");
        }
        catch (AsoCliException error)
        {
            Error(error.Message);
        }
        finally
        {
            IsBusy = false;
        }
    }
}
