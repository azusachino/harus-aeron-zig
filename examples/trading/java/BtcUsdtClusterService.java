package trading;

import io.aeron.ExclusivePublication;
import io.aeron.Image;
import io.aeron.cluster.codecs.CloseReason;
import io.aeron.cluster.service.ClientSession;
import io.aeron.cluster.service.Cluster;
import io.aeron.cluster.service.ClusteredService;
import io.aeron.logbuffer.Header;
import org.agrona.DirectBuffer;
import org.agrona.ExpandableArrayBuffer;

public final class BtcUsdtClusterService implements ClusteredService
{
    private final TradingOrderBook book = new TradingOrderBook();
    private final ExpandableArrayBuffer response = new ExpandableArrayBuffer(256);

    @Override
    public void onStart(final Cluster cluster, final Image snapshotImage)
    {
        // Snapshot support is added after the baseline replay path is proven.
    }

    @Override
    public void onSessionOpen(final ClientSession session, final long timestamp) {}

    @Override
    public void onSessionClose(final ClientSession session, final long timestamp, final CloseReason closeReason) {}

    @Override
    public void onSessionMessage(
        final ClientSession session,
        final long timestamp,
        final DirectBuffer buffer,
        final int offset,
        final int length,
        final Header header)
    {
        if (session == null)
        {
            return;
        }

        final String event = buffer.getStringWithoutLengthAscii(offset, length);
        final String[] fields = event.split("\\|", -1);
        if (fields.length != 5 || !TradingOrderBook.SYMBOL.equals(fields[0]))
        {
            respond(session, "BTC_USDT|0|REJECTED|bad-event");
            return;
        }

        try
        {
            final TradingOrderBook.Order order = new TradingOrderBook.Order(
                Long.parseLong(fields[1]),
                TradingOrderBook.Side.valueOf(fields[2]),
                Long.parseLong(fields[3]),
                Long.parseLong(fields[4]));
            final TradingOrderBook.SubmitResult result = book.submit(order);
            respond(session, "BTC_USDT|" + order.orderId() + "|FILLED|" + result.filledQuantity() +
                "|RESTING|" + result.restingQuantity());
        }
        catch (final RuntimeException ex)
        {
            respond(session, "BTC_USDT|0|REJECTED|" + ex.getClass().getSimpleName());
        }
    }

    private void respond(final ClientSession session, final String value)
    {
        final int length = response.putStringWithoutLengthAscii(0, value);
        while (session.offer(response, 0, length) < 0)
        {
            Thread.yield();
        }
    }

    @Override
    public void onTimerEvent(final long correlationId, final long timestamp) {}

    @Override
    public void onTakeSnapshot(final ExclusivePublication snapshotPublication) {}

    @Override
    public void onRoleChange(final Cluster.Role newRole) {}

    @Override
    public void onTerminate(final Cluster cluster) {}
}
