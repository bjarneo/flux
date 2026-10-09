namespace Flux.Protocol;

public readonly record struct ConnectionObservation(bool Busy, bool TargetReady);

public static class ConnectionAttempt
{
    // A peer behind an inbound firewall may dial us on its next retry.
    // An idle slot means keep listening, not that this attempt is finished.
    public static async Task<bool> WaitForTargetAsync(
        Func<CancellationToken, Task<ConnectionObservation>> observe,
        TimeSpan timeout, CancellationToken shutdown)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(shutdown);
        deadline.CancelAfter(timeout);
        try {
            while (true) {
                deadline.Token.ThrowIfCancellationRequested();
                if ((await observe(deadline.Token)).TargetReady) return true;
                await Task.Delay(50, deadline.Token);
            }
        } catch (OperationCanceledException) when (!shutdown.IsCancellationRequested) {
            return false;
        }
    }

    // An occupied handshake slot is not proof that the requested peer connected.
    // Wait for that peer, or for the slot to become available; never silently
    // return success merely because some other handshake claimed the slot.
    public static async Task<bool> WaitAsync(
        Func<CancellationToken, Task<ConnectionObservation>> observe,
        TimeSpan timeout, CancellationToken shutdown)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(shutdown);
        deadline.CancelAfter(timeout);
        try {
            while (true) {
                deadline.Token.ThrowIfCancellationRequested();
                var current = await observe(deadline.Token);
                if (current.TargetReady) return true;
                if (!current.Busy) return false;
                await Task.Delay(20, deadline.Token);
            }
        } catch (OperationCanceledException) when (!shutdown.IsCancellationRequested) {
            throw new TimeoutException("The selected device did not finish connecting. Another handshake is still occupying the connection slot.");
        }
    }
}
