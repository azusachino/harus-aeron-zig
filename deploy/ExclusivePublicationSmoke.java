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

public final class ExclusivePublicationSmoke
{
    private static final String CHANNEL =
        System.getProperty("aeron.sample.channel", "aeron:udp?endpoint=localhost:20121");
    private static final int STREAM_ID = 3001;
    private static final int MESSAGE_COUNT = Integer.getInteger("MESSAGE_COUNT", 10);
    private static final long TIMEOUT_NS = TimeUnit.SECONDS.toNanos(15);

    private ExclusivePublicationSmoke()
    {
    }

    public static void main(final String[] args)
    {
        System.out.println(
            "Running exclusive publication smoke on " + CHANNEL +
            " stream=" + STREAM_ID +
            " messages=" + MESSAGE_COUNT);

        final Aeron.Context ctx = new Aeron.Context();
        ctx.aeronDirectoryName(System.getProperty("aeron.dir", "/dev/shm/aeron"));

        try (Aeron aeron = Aeron.connect(ctx))
        {
            // Add subscription on the exclusive channel/stream
            try (Subscription subscription = aeron.addSubscription(CHANNEL, STREAM_ID))
            {
                // Add first exclusive publication
                try (Publication publication1 = aeron.addExclusivePublication(CHANNEL, STREAM_ID))
                {
                    awaitConnected(publication1, "publication1");

                    // Publish messages with the first exclusive publication
                    for (int i = 0; i < MESSAGE_COUNT; i++)
                    {
                        final String payload = "exclusive-msg-" + i;
                        final byte[] data = payload.getBytes(StandardCharsets.US_ASCII);
                        final UnsafeBuffer buffer = new UnsafeBuffer(data);
                        awaitOffer(publication1, buffer, data.length, "publication1");
                    }

                    // Poll subscription and verify all messages received
                    final SmokeState state = new SmokeState();
                    final FragmentHandler handler = (fragment, offset, length, header) ->
                    {
                        final byte[] received = new byte[length];
                        fragment.getBytes(offset, received, 0, length);
                        final String payload = new String(received, StandardCharsets.US_ASCII);

                        // Verify payload format
                        if (!payload.startsWith("exclusive-msg-"))
                        {
                            throw new IllegalStateException("Unexpected payload format: " + payload);
                        }
                        state.receivedCount++;
                    };

                    awaitFragments(subscription, handler, state);

                    if (state.receivedCount != MESSAGE_COUNT)
                    {
                        throw new IllegalStateException(
                            "Expected " + MESSAGE_COUNT + " messages, got " + state.receivedCount);
                    }

                    // A second exclusive publication on the same channel/stream is valid — each gets
                    // its own independent session (Aeron exclusive = exclusive per session, not per stream).
                    // Upstream: ExclusivePublicationTest#shouldPublishFromIndependentExclusivePublications
                    try (Publication publication2 = aeron.addExclusivePublication(CHANNEL, STREAM_ID))
                    {
                        awaitConnected(publication2, "publication2");

                        final String testPayload = "exclusive-msg-second";
                        final byte[] testData = testPayload.getBytes(StandardCharsets.US_ASCII);
                        final UnsafeBuffer testBuffer = new UnsafeBuffer(testData);

                        awaitOffer(publication2, testBuffer, testData.length, "publication2");
                        System.out.println("Second exclusive publication sent independently as expected");
                    }

                    // Signal successful completion
                    try
                    {
                        new File("/tmp/exclusive-done").createNewFile();
                    }
                    catch (final IOException ex)
                    {
                        System.out.println("WARN: Failed to create exclusive-done marker file: " + ex.getMessage());
                    }

                    System.out.println("ExclusivePublication OK");
                }
            }
        }
        catch (final Exception ex)
        {
            System.out.println("FAIL: " + ex.getMessage());
            ex.printStackTrace();
            System.exit(1);
        }
    }

    private static void awaitConnected(final Publication publication, final String name)
    {
        final long deadline = System.nanoTime() + TIMEOUT_NS;
        while (!publication.isConnected())
        {
            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException("Timed out waiting for " + name + " to connect");
            }

            sleepQuietly(10);
        }
    }

    private static void awaitOffer(
        final Publication publication,
        final UnsafeBuffer buffer,
        final int length,
        final String name)
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
                    "Timed out offering " + name + " data; last result=" + Publication.errorString(position));
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
        }
    }

    private static class SmokeState
    {
        int receivedCount = 0;
    }
}
