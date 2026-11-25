using FluxKit;

namespace FluxKit.Tests;

public class ShareModelTests
{
    static FileTransfer Transfer(long size = 100) => new() { DeviceId = "d", Name = "a.txt", Incoming = true, Size = size };

    [Fact]
    public void TransfersAreNewestFirstAndKeepALimit()
    {
        var model = new ShareModel();
        var all = Enumerable.Range(0, ShareModel.MaxTransfers + 5).Select(_ => Transfer()).ToList();
        foreach (var t in all)
        {
            model.Start(t);
        }
        Assert.Equal(ShareModel.MaxTransfers, model.Transfers.Count);
        Assert.Equal(all[^1].Id, model.Transfers[0].Id);
        Assert.DoesNotContain(model.Transfers, t => t.Id == all[0].Id);
    }

    [Fact]
    public void ProgressOnlyGrowsWhileTheTransferRuns()
    {
        var model = new ShareModel();
        var t = Transfer();
        model.Start(t);
        var changes = new List<string?>();
        model.PropertyChanged += (_, e) => changes.Add(e.PropertyName);
        model.Progress(t.Id, 40);
        model.Progress(t.Id, 30);
        Assert.Equal(40, model.Transfers[0].Bytes);
        Assert.Equal(0.4, model.Transfers[0].Fraction);
        model.Finish(t.Id, null, TransferState.Failed, "the computer did not connect in time");
        model.Progress(t.Id, 90);
        Assert.Equal(40, model.Transfers[0].Bytes);
        Assert.Equal(TransferState.Failed, model.Transfers[0].State);
        Assert.Equal("the computer did not connect in time", model.Transfers[0].Error);
        Assert.NotNull(model.Transfers[0].Ended);
        // A change that changes nothing reports nothing.
        Assert.Equal([nameof(ShareModel.Transfers), nameof(ShareModel.Transfers)], changes);
    }

    [Fact]
    public void FinishSetsTheSavedFile()
    {
        var model = new ShareModel();
        var t = Transfer();
        model.Start(t);
        var saved = Path.Combine(Path.GetTempPath(), "a (2).txt");
        model.Finish(t.Id, saved, TransferState.Done);
        var done = model.Transfers[0];
        Assert.Equal(TransferState.Done, done.State);
        Assert.Equal(100, done.Bytes);
        Assert.Equal(saved, done.File);
        Assert.Equal("a (2).txt", done.Name);
        Assert.Null(done.Error);
    }

    [Fact]
    public void ResumeRunsTheEntryAgain()
    {
        var model = new ShareModel();
        var t = Transfer();
        model.Start(t);
        model.Progress(t.Id, 50);
        model.Finish(t.Id, null, TransferState.Failed, "lost");
        model.Resume(t);
        Assert.Single(model.Transfers);
        Assert.Equal(TransferState.Running, model.Transfers[0].State);
        Assert.Equal(50, model.Transfers[0].Bytes);
        Assert.Null(model.Transfers[0].Error);
        Assert.Null(model.Transfers[0].Ended);

        // An entry that left the list comes back at the top.
        model.ClearFinished();
        var other = Transfer();
        model.Start(other);
        model.Finish(other.Id, null, TransferState.Done);
        model.ClearFinished();
        Assert.Single(model.Transfers);
        var gone = Transfer();
        model.Resume(gone);
        Assert.Equal(gone.Id, model.Transfers[0].Id);
    }

    [Fact]
    public void ClearFinishedKeepsTheRunningTransfers()
    {
        var model = new ShareModel();
        var running = Transfer();
        var done = Transfer();
        var canceled = Transfer();
        model.Start(running);
        model.Start(done);
        model.Start(canceled);
        model.Finish(done.Id, null, TransferState.Done);
        model.Finish(canceled.Id, null, TransferState.Canceled);
        model.ClearFinished();
        Assert.Equal(running.Id, Assert.Single(model.Transfers).Id);
    }

    [Fact]
    public void UnknownSizeHasNoFraction()
    {
        Assert.Null((Transfer(-1) with { Bytes = 5 }).Fraction);
        Assert.Equal(1, (Transfer(10) with { Bytes = 50 }).Fraction);
    }

    [Fact]
    public void SentItemsKeepTheNewest()
    {
        var model = new ShareModel();
        for (var i = 0; i < ShareModel.MaxSent + 3; i++)
        {
            model.Record(new SentItem("d", SentKind.Text, $"t{i}"));
        }
        Assert.Equal(ShareModel.MaxSent, model.Sent.Count);
        Assert.Equal("t3", model.Sent[0].Text);
        Assert.Equal($"t{ShareModel.MaxSent + 2}", model.Sent[^1].Text);
    }

    [Fact]
    public void SentItemCutsALongText()
    {
        var item = new SentItem("d", SentKind.Text, "  " + new string('x', 1000) + "\n");
        Assert.Equal(SentItem.MaxText, item.Text.Length);
        Assert.EndsWith("x…", item.Text);
        Assert.Equal("short", new SentItem("d", SentKind.Link, " short ").Text);
        // The cut counts characters as the user sees them.
        var emoji = new SentItem("d", SentKind.Text, string.Concat(Enumerable.Repeat("👍🏽", 500)));
        Assert.EndsWith("👍🏽…", emoji.Text);
    }
}
