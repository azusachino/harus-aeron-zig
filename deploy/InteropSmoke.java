import io.aeron.Aeron;
import io.aeron.Publication;
import io.aeron.Subscription;
import io.aeron.logbuffer.FragmentHandler;
import org.agrona.concurrent.UnsafeBuffer;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.TimeUnit;

public final class InteropSmoke
{
    private static final String CHANNEL =
        System.getProperty("aeron.sample.channel", "aeron:udp?endpoint=localhost:20121");
    private static final int STREAM_ID = Integer.getInteger("aeron.sample.streamId", 1001);
    private static final int MESSAGE_COUNT = Integer.getInteger("aeron.sample.messageCount", 10);
    private static final long TIMEOUT_NS = TimeUnit.SECONDS.toNanos(15);

    private InteropSmoke()
    {
    }

    public static void main(final String[] args)
    {
        System.out.println(
            "Running finite publication smoke on " + CHANNEL +
            " stream=" + STREAM_ID +
            " messages=" + MESSAGE_COUNT);

        final Aeron.Context ctx = new Aeron.Context();
        ctx.aeronDirectoryName(System.getProperty("aeron.dir", "/dev/shm/aeron"));

        try (Aeron aeron = Aeron.connect(ctx);
            Subscription subscription = aeron.addSubscription(CHANNEL, STREAM_ID);
            Publication publication = aeron.addPublication(CHANNEL, STREAM_ID))
        {
            awaitConnected(publication);

            final byte[] payload = "interop-smoke-payload".getBytes(StandardCharsets.US_ASCII);
            final UnsafeBuffer buffer = new UnsafeBuffer(payload);
            final SmokeState state = new SmokeState();
            final FragmentHandler handler = (fragment, offset, length, header) ->
            {
                final byte[] received = new byte[length];
                fragment.getBytes(offset, received, 0, length);
                if (!Arrays.equals(received, payload))
                {
                    throw new IllegalStateException("Unexpected payload received from publication path");
                }
                state.receivedCount++;
            };

            for (int i = 0; i < MESSAGE_COUNT; i++)
            {
                awaitOffer(publication, buffer, payload.length);
            }

            awaitFragments(subscription, handler, state);
        }

        System.out.println("Smoke OK");
    }

    private static void awaitConnected(final Publication publication)
    {
        final long deadline = System.nanoTime() + TIMEOUT_NS;
        while (!publication.isConnected())
        {
            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException("Timed out waiting for publication to connect");
            }

            sleepQuietly(10);
        }
    }

    private static void awaitOffer(final Publication publication, final UnsafeBuffer buffer, final int length)
    {
        final long deadline = System.nanoTime() + TIMEOUT_NS;
        while (true)
        {
            final long position = publication.offer(buffer, 0, length);
            if (position > 0)
            {
                return;
            }

            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException("Timed out offering publication data");
            }

            sleepQuietly(1);
        }
    }

    private static void awaitFragments(
        final Subscription subscription,
        final FragmentHandler handler,
        final SmokeState state)
    {
        final long deadline = System.nanoTime() + TIMEOUT_NS;
        while (state.receivedCount < MESSAGE_COUNT)
        {
            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException("Timed out waiting for published data");
            }

            final int fragments = subscription.poll(handler, MESSAGE_COUNT);
            if (fragments == 0)
            {
                sleepQuietly(1);
            }
        }
    }

    private static void sleepQuietly(final long millis)
    {
        try
        {
            Thread.sleep(millis);
        }
        catch (final InterruptedException ex)
        {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while waiting for smoke progress", ex);
        }
    }

    private static final class SmokeState
    {
        private int receivedCount;
    }
}
