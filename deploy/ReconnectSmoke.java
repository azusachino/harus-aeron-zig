import io.aeron.Aeron;
import io.aeron.Publication;
import io.aeron.Subscription;
import io.aeron.logbuffer.FragmentHandler;
import org.agrona.concurrent.UnsafeBuffer;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.TimeUnit;

public final class ReconnectSmoke
{
    private static final String CHANNEL =
        System.getProperty("aeron.sample.channel", "aeron:udp?endpoint=localhost:20121");
    private static final int STREAM_ID = 4001;
    private static final int MESSAGE_COUNT = Integer.getInteger("MESSAGE_COUNT", 10);
    private static final long TIMEOUT_NS = TimeUnit.SECONDS.toNanos(15);
    private static final long CLEANUP_SLEEP_MS = 2000;

    private ReconnectSmoke()
    {
    }

    public static void main(final String[] args)
    {
        System.out.println(
            "Running reconnect smoke test on " + CHANNEL +
            " stream=" + STREAM_ID +
            " messages=" + MESSAGE_COUNT);

        try
        {
            // Phase 1: Create context, connect, publish, receive, then close
            System.out.println("Phase 1: Initial connection...");
            phase1();
            System.out.println("Phase 1: OK");

            // Sleep to allow driver to clean up resources
            System.out.println("Sleeping " + CLEANUP_SLEEP_MS + "ms for driver cleanup...");
            sleepQuietly(CLEANUP_SLEEP_MS);

            // Phase 2: Create new context, reconnect, publish, receive
            System.out.println("Phase 2: Reconnection...");
            phase2();
            System.out.println("Phase 2: OK");

            // Signal completion
            try
            {
                new File("/tmp/reconnect-done").createNewFile();
            }
            catch (final IOException ex)
            {
                System.out.println("WARN: Failed to create reconnect-done marker file: " + ex.getMessage());
            }

            System.out.println("Reconnect OK");
            System.exit(0);
        }
        catch (final Exception ex)
        {
            System.out.println("FAIL: " + ex.getMessage());
            ex.printStackTrace();
            System.exit(1);
        }
    }

    private static void phase1()
    {
        final Aeron.Context ctx = new Aeron.Context();
        ctx.aeronDirectoryName(System.getProperty("aeron.dir", "/dev/shm/aeron"));

        try (Aeron aeron = Aeron.connect(ctx);
            Subscription subscription = aeron.addSubscription(CHANNEL, STREAM_ID);
            Publication publication = aeron.addPublication(CHANNEL, STREAM_ID))
        {
            awaitConnected(publication, "Phase 1");

            final ReconnectState state = new ReconnectState();
            final FragmentHandler handler = (fragment, offset, length, header) ->
            {
                final byte[] received = new byte[length];
                fragment.getBytes(offset, received, 0, length);
                final String payload = new String(received, StandardCharsets.US_ASCII);

                final String expectedPrefix = "reconnect-phase1-msg-";
                if (!payload.startsWith(expectedPrefix))
                {
                    throw new IllegalStateException(
                        "Phase 1: Unexpected payload received: " + payload);
                }
                state.receivedCount++;
            };

            // Publish phase 1 messages
            for (int i = 0; i < MESSAGE_COUNT; i++)
            {
                final String payload = "reconnect-phase1-msg-" + i;
                final byte[] data = payload.getBytes(StandardCharsets.US_ASCII);
                final UnsafeBuffer buffer = new UnsafeBuffer(data);
                awaitOffer(publication, buffer, data.length, "Phase 1");
            }

            // Receive all phase 1 messages
            awaitFragments(subscription, handler, state, MESSAGE_COUNT, "Phase 1");

            if (state.receivedCount != MESSAGE_COUNT)
            {
                throw new IllegalStateException(
                    "Phase 1: Expected " + MESSAGE_COUNT + " messages, received " + state.receivedCount);
            }
        }
    }

    private static void phase2()
    {
        final Aeron.Context ctx = new Aeron.Context();
        ctx.aeronDirectoryName(System.getProperty("aeron.dir", "/dev/shm/aeron"));

        try (Aeron aeron = Aeron.connect(ctx);
            Subscription subscription = aeron.addSubscription(CHANNEL, STREAM_ID);
            Publication publication = aeron.addPublication(CHANNEL, STREAM_ID))
        {
            awaitConnected(publication, "Phase 2");

            final ReconnectState state = new ReconnectState();
            final FragmentHandler handler = (fragment, offset, length, header) ->
            {
                final byte[] received = new byte[length];
                fragment.getBytes(offset, received, 0, length);
                final String payload = new String(received, StandardCharsets.US_ASCII);

                final String expectedPrefix = "reconnect-phase2-msg-";
                if (!payload.startsWith(expectedPrefix))
                {
                    throw new IllegalStateException(
                        "Phase 2: Unexpected payload received: " + payload);
                }
                state.receivedCount++;
            };

            // Publish phase 2 messages
            for (int i = 0; i < MESSAGE_COUNT; i++)
            {
                final String payload = "reconnect-phase2-msg-" + i;
                final byte[] data = payload.getBytes(StandardCharsets.US_ASCII);
                final UnsafeBuffer buffer = new UnsafeBuffer(data);
                awaitOffer(publication, buffer, data.length, "Phase 2");
            }

            // Receive all phase 2 messages
            awaitFragments(subscription, handler, state, MESSAGE_COUNT, "Phase 2");

            if (state.receivedCount != MESSAGE_COUNT)
            {
                throw new IllegalStateException(
                    "Phase 2: Expected " + MESSAGE_COUNT + " messages, received " + state.receivedCount);
            }
        }
    }

    private static void awaitConnected(final Publication publication, final String phase)
    {
        final long deadline = System.nanoTime() + TIMEOUT_NS;
        while (!publication.isConnected())
        {
            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException(phase + ": Timed out waiting for publication to connect");
            }

            sleepQuietly(10);
        }
    }

    private static void awaitOffer(
        final Publication publication,
        final UnsafeBuffer buffer,
        final int length,
        final String phase)
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
                throw new IllegalStateException(
                    phase + ": Timed out offering publication data; last result=" +
                    Publication.errorString(position));
            }

            sleepQuietly(1);
        }
    }

    private static void awaitFragments(
        final Subscription subscription,
        final FragmentHandler handler,
        final ReconnectState state,
        final int expectedCount,
        final String phase)
    {
        final long deadline = System.nanoTime() + TIMEOUT_NS;
        while (state.receivedCount < expectedCount)
        {
            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException(
                    phase + ": Timed out waiting for published data; received " +
                    state.receivedCount + " expected " + expectedCount);
            }

            final int fragments = subscription.poll(handler, expectedCount);
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

    private static final class ReconnectState
    {
        int receivedCount;
    }
}
