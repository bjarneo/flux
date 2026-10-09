namespace Flux.Protocol;

// One cancellation source for the connection, rather than a disposed source
// per packet. The caller serializes state changes with its connection lock.
public sealed class ReadLifetime : IDisposable
{
    private readonly CancellationTokenSource source;
    private readonly TimeSpan unpairedIdle;
    public CancellationToken Token => source.Token;
    public ReadLifetime(CancellationToken shutdown, TimeSpan? unpairedIdle = null)
    {
        source = CancellationTokenSource.CreateLinkedTokenSource(shutdown);
        this.unpairedIdle = unpairedIdle ?? TimeSpan.FromMinutes(2);
    }
    public void SetPaired(bool paired) => source.CancelAfter(paired ? Timeout.InfiniteTimeSpan : unpairedIdle);
    public void Stop() => source.Cancel();
    public void Dispose() => source.Dispose();
}
