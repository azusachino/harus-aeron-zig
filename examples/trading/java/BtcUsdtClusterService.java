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

import java.util.ArrayDeque;
import java.util.Deque;
import java.util.concurrent.TimeUnit;

public final class BtcUsdtClusterService implements ClusteredService
{
    private static final long RESPONSE_RETRY_TIMER_ID = 1;

    private final TradingOrderBook book = new TradingOrderBook();
    private final ExpandableArrayBuffer response = new ExpandableArrayBuffer(256);
    private final Deque<PendingResponse> pendingResponses = new ArrayDeque<>();
    private boolean responseRetryScheduled;
    private Cluster cluster;
    private long sessionMessages;
    private long responsesOffered;
    private long responseBackPressure;
    private long timerRetries;

    private record PendingResponse(ClientSession session, String value) {}

    @Override
    public void onStart(final Cluster cluster, final Image snapshotImage)
    {
        this.cluster = cluster;
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

        sessionMessages++;
        if ((sessionMessages % 1000) == 0)
        {
            System.out.println("JAVA_CLUSTER_SERVICE_PROGRESS messages=" + sessionMessages +
                " responses=" + responsesOffered + " back_pressure=" + responseBackPressure +
                " timer_retries=" + timerRetries);
        }

        final String event = buffer.getStringWithoutLengthAscii(offset, length);
        final String[] fields = event.split("\\|", -1);
        if (fields.length != 5 || !TradingOrderBook.SYMBOL.equals(fields[0]))
        {
            enqueueResponse(session, "BTC_USDT|0|REJECTED|bad-event");
            drainResponses(cluster);
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
            enqueueResponse(session, "BTC_USDT|" + order.orderId() + "|FILLED|" + result.filledQuantity() +
                "|RESTING|" + result.restingQuantity());
        }
        catch (final RuntimeException ex)
        {
            enqueueResponse(session, "BTC_USDT|0|REJECTED|" + ex.getClass().getSimpleName());
        }

        drainResponses(cluster);
    }

    private void enqueueResponse(final ClientSession session, final String value)
    {
        pendingResponses.addLast(new PendingResponse(session, value));
    }

    private void drainResponses(final Cluster cluster)
    {
        while (!pendingResponses.isEmpty())
        {
            final PendingResponse pending = pendingResponses.peekFirst();
            final int length = response.putStringWithoutLengthAscii(0, pending.value());
            final long offerResult = pending.session().offer(response, 0, length);
            if (offerResult < 0)
            {
                responseBackPressure++;
                if (responseBackPressure == 1 || (responseBackPressure % 1000) == 0)
                {
                    System.out.println("JAVA_CLUSTER_SERVICE_RESPONSE_BACK_PRESSURE messages=" + sessionMessages +
                        " responses=" + responsesOffered + " back_pressure=" + responseBackPressure +
                        " timer_retries=" + timerRetries + " result=" + offerResult);
                }
                if (cluster != null)
                {
                    scheduleResponseRetry(cluster);
                }
                return;
            }
            responsesOffered++;
            pendingResponses.removeFirst();
        }

        responseRetryScheduled = false;
    }

    private void scheduleResponseRetry(final Cluster cluster)
    {
        if (responseRetryScheduled)
        {
            return;
        }

        responseRetryScheduled = true;
        final long delay = cluster.timeUnit().convert(1, TimeUnit.MILLISECONDS);
        cluster.idleStrategy().reset();
        while (!cluster.scheduleTimer(RESPONSE_RETRY_TIMER_ID, cluster.time() + delay))
        {
            cluster.idleStrategy().idle();
        }
    }

    @Override
    public void onTimerEvent(final long correlationId, final long timestamp)
    {
        if (correlationId == RESPONSE_RETRY_TIMER_ID)
        {
            timerRetries++;
            if (timerRetries == 1 || (timerRetries % 1000) == 0)
            {
                System.out.println("JAVA_CLUSTER_SERVICE_TIMER_RETRY messages=" + sessionMessages +
                    " responses=" + responsesOffered + " back_pressure=" + responseBackPressure +
                    " timer_retries=" + timerRetries);
            }
            responseRetryScheduled = false;
            drainResponses(cluster);
        }
    }

    @Override
    public void onTakeSnapshot(final ExclusivePublication snapshotPublication) {}

    @Override
    public void onRoleChange(final Cluster.Role newRole) {}

    @Override
    public void onTerminate(final Cluster cluster) {}
}
