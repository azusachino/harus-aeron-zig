import io.aeron.Aeron;
import io.aeron.Publication;
import io.aeron.Subscription;
import io.aeron.logbuffer.FragmentHandler;
import org.agrona.concurrent.UnsafeBuffer;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

public final class MultiStreamSmoke
{
    private static final String CHANNEL =
        System.getProperty("aeron.sample.channel", "aeron:udp?endpoint=localhost:20121");
    private static final int MESSAGE_COUNT = Integer.getInteger("MESSAGE_COUNT", 10);
    private static final long TIMEOUT_NS = TimeUnit.SECONDS.toNanos(15);

    private static final int[] STREAM_IDS = { 2001, 2002, 2003 };

    private MultiStreamSmoke()
    {
    }

    public static void main(final String[] args)
    {
        System.out.println(
            "Running multi-stream smoke test on " + CHANNEL +
            " streams=" + Arrays.toString(STREAM_IDS) +
            " messages=" + MESSAGE_COUNT);

        final Aeron.Context ctx = new Aeron.Context();
        ctx.aeronDirectoryName(System.getProperty("aeron.dir", "/dev/shm/aeron"));

        try (Aeron aeron = Aeron.connect(ctx))
        {
            final Publication[] publications = new Publication[STREAM_IDS.length];
            final Subscription[] subscriptions = new Subscription[STREAM_IDS.length];

            for (int i = 0; i < STREAM_IDS.length; i++)
            {
                publications[i] = aeron.addPublication(CHANNEL, STREAM_IDS[i]);
                subscriptions[i] = aeron.addSubscription(CHANNEL, STREAM_IDS[i]);
            }

            // Wait for all publications to connect
            for (int i = 0; i < publications.length; i++)
            {
                awaitConnected(publications[i], STREAM_IDS[i]);
            }

            // Create state for each stream
            final StreamState[] states = new StreamState[STREAM_IDS.length];
            for (int i = 0; i < STREAM_IDS.length; i++)
            {
                states[i] = new StreamState(STREAM_IDS[i]);
            }

            // Publish messages on all streams
            for (int i = 0; i < STREAM_IDS.length; i++)
            {
                final int streamIdx = i;
                final int streamId = STREAM_IDS[i];
                for (int msgNum = 0; msgNum < MESSAGE_COUNT; msgNum++)
                {
                    final String payload = "stream-" + streamId + "-msg-" + msgNum;
                    final byte[] data = payload.getBytes(StandardCharsets.US_ASCII);
                    final UnsafeBuffer buffer = new UnsafeBuffer(data);
                    awaitOffer(publications[streamIdx], buffer, data.length, streamId);
                }
            }

            // Poll all subscriptions verifying correct message routing
            final long deadline = System.nanoTime() + TIMEOUT_NS;
            int totalReceived = 0;
            while (totalReceived < STREAM_IDS.length * MESSAGE_COUNT)
            {
                if (System.nanoTime() > deadline)
                {
                    System.out.println("FAIL: Timed out waiting for messages");
                    for (int i = 0; i < STREAM_IDS.length; i++)
                    {
                        System.out.println(
                            "  Stream " + STREAM_IDS[i] +
                            ": received " + states[i].receivedCount +
                            " expected " + MESSAGE_COUNT);
                    }
                    System.exit(1);
                }

                int fragmentsPolled = 0;
                for (int i = 0; i < subscriptions.length; i++)
                {
                    final int streamIdx = i;
                    final FragmentHandler handler = (fragment, offset, length, header) ->
                    {
                        final byte[] received = new byte[length];
                        fragment.getBytes(offset, received, 0, length);
                        final String payload = new String(received, StandardCharsets.US_ASCII);

                        final String expectedPrefix = "stream-" + STREAM_IDS[streamIdx] + "-msg-";
                        if (!payload.startsWith(expectedPrefix))
                        {
                            System.out.println("FAIL: Stream " + STREAM_IDS[streamIdx] +
                                " received unexpected payload: " + payload);
                            System.exit(1);
                        }

                        states[streamIdx].receivedCount++;
                    };

                    final int polled = subscriptions[i].poll(handler, MESSAGE_COUNT);
                    fragmentsPolled += polled;
                }

                totalReceived = 0;
                for (int i = 0; i < STREAM_IDS.length; i++)
                {
                    totalReceived += states[i].receivedCount;
                }

                if (fragmentsPolled == 0)
                {
                    sleepQuietly(1);
                }
            }

            // Verify all streams received all messages
            for (int i = 0; i < STREAM_IDS.length; i++)
            {
                if (states[i].receivedCount != MESSAGE_COUNT)
                {
                    System.out.println("FAIL: Stream " + STREAM_IDS[i] +
                        " received " + states[i].receivedCount +
                        " messages, expected " + MESSAGE_COUNT);
                    System.exit(1);
                }
            }

            // Signal completion
            try
            {
                new File("/tmp/multistream-done").createNewFile();
            }
            catch (final IOException ex)
            {
                System.out.println("WARN: Failed to create multistream-done marker file: " + ex.getMessage());
            }

            System.out.println("MultiStream OK");
        }
        catch (final Exception ex)
        {
            System.out.println("FAIL: " + ex.getMessage());
            ex.printStackTrace();
            System.exit(1);
        }
    }

    private static void awaitConnected(final Publication publication, final int streamId)
    {
        final long deadline = System.nanoTime() + TIMEOUT_NS;
        while (!publication.isConnected())
        {
            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException(
                    "Timed out waiting for publication to connect on stream " + streamId);
            }

            sleepQuietly(10);
        }
    }

    private static void awaitOffer(
        final Publication publication,
        final UnsafeBuffer buffer,
        final int length,
        final int streamId)
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
                    "Timed out offering publication data on stream " + streamId +
                    "; last result=" + Publication.errorString(position));
            }

            sleepQuietly(1);
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

    private static final class StreamState
    {
        final int streamId;
        int receivedCount;

        private StreamState(final int streamId)
        {
            this.streamId = streamId;
            this.receivedCount = 0;
        }
    }
}
