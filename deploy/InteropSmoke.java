import io.aeron.Aeron;
import io.aeron.AeronCounters;
import io.aeron.Publication;
import io.aeron.Subscription;
import io.aeron.driver.status.StreamCounter;
import io.aeron.logbuffer.FragmentHandler;
import io.aeron.status.ChannelEndpointStatus;
import org.agrona.DirectBuffer;
import org.agrona.concurrent.UnsafeBuffer;
import org.agrona.concurrent.status.CountersReader;

import java.io.File;
import java.io.IOException;
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
            verifyCounters(aeron, publication, subscription, 0L);

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
            verifyCounters(aeron, publication, subscription, publication.position());

            // Signal CountersChecker that counters are ready for external validation
            try
            {
                new File("/tmp/smoke-ready").createNewFile();
            }
            catch (final IOException ex)
            {
                System.out.println("WARN: Failed to create smoke-ready marker file: " + ex.getMessage());
            }
            System.out.println("Smoke OK — holding connection for external counter validation");

            // Wait for checker to finish (up to 30s)
            final File checkerDone = new File("/tmp/checker-done");
            final long holdDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30);
            while (!checkerDone.exists())
            {
                if (System.nanoTime() > holdDeadline)
                {
                    System.out.println("WARN: CountersChecker did not signal completion — proceeding to close");
                    break;
                }
                sleepQuietly(100);
            }
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
                throw new IllegalStateException(
                    "Timed out offering publication data; last result=" + Publication.errorString(position));
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

    private static void verifyCounters(
        final Aeron aeron,
        final Publication publication,
        final Subscription subscription,
        final long minimumPublisherLimit)
    {
        final CountersReader counters = aeron.countersReader();

        final StreamCounterSnapshot pubLimit = findStreamCounter(
            counters,
            AeronCounters.DRIVER_PUBLISHER_LIMIT_TYPE_ID,
            publication.registrationId(),
            publication.sessionId(),
            publication.streamId(),
            CHANNEL);
        if (pubLimit == null)
        {
            throw new IllegalStateException("Missing publisher-limit counter for registrationId=" +
                publication.registrationId());
        }
        if (pubLimit.value < minimumPublisherLimit)
        {
            throw new IllegalStateException("Publisher-limit counter did not advance enough: value=" +
                pubLimit.value + " minimum=" + minimumPublisherLimit);
        }

        final StreamCounterSnapshot senderPos = findStreamCounter(
            counters,
            AeronCounters.DRIVER_SENDER_POSITION_TYPE_ID,
            publication.registrationId(),
            publication.sessionId(),
            publication.streamId(),
            CHANNEL);
        if (senderPos == null)
        {
            throw new IllegalStateException("Missing sender-position counter for registrationId=" +
                publication.registrationId());
        }

        final StreamCounterSnapshot subscriberPos = awaitStreamCounter(
            counters,
            AeronCounters.DRIVER_SUBSCRIBER_POSITION_TYPE_ID,
            subscription.registrationId(),
            publication.sessionId(),
            publication.streamId(),
            CHANNEL);
        if (subscriberPos.value < 0)
        {
            throw new IllegalStateException("Subscriber-position counter is negative: value=" +
                subscriberPos.value);
        }

        final StreamCounterSnapshot receiverHwm = awaitStreamCounter(
            counters,
            AeronCounters.DRIVER_RECEIVER_HWM_TYPE_ID,
            subscription.registrationId(),
            publication.sessionId(),
            publication.streamId(),
            CHANNEL);
        if (receiverHwm.value < subscriberPos.value)
        {
            throw new IllegalStateException("Receiver HWM below subscriber position: hwm=" +
                receiverHwm.value + " subPos=" + subscriberPos.value);
        }

        final CounterSnapshot sendChannelStatus = awaitChannelStatusCounter(
            counters,
            AeronCounters.DRIVER_SEND_CHANNEL_STATUS_TYPE_ID,
            publication.channelStatusId(),
            publication.registrationId(),
            CHANNEL);
        if (sendChannelStatus.value != ChannelEndpointStatus.ACTIVE)
        {
            throw new IllegalStateException("Send channel status not ACTIVE for publication counterId=" +
                publication.channelStatusId() + " value=" + sendChannelStatus.value);
        }

        final CounterSnapshot receiveChannelStatus = awaitChannelStatusCounter(
            counters,
            AeronCounters.DRIVER_RECEIVE_CHANNEL_STATUS_TYPE_ID,
            subscription.channelStatusId(),
            subscription.registrationId(),
            CHANNEL);
        if (receiveChannelStatus.value != ChannelEndpointStatus.ACTIVE)
        {
            throw new IllegalStateException("Receive channel status not ACTIVE for subscription counterId=" +
                subscription.channelStatusId() + " value=" + receiveChannelStatus.value);
        }
    }

    private static StreamCounterSnapshot awaitStreamCounter(
        final CountersReader counters,
        final int typeId,
        final long registrationId,
        final int sessionId,
        final int streamId,
        final String channel)
    {
        final long deadline = System.nanoTime() + TIMEOUT_NS;
        while (true)
        {
            final StreamCounterSnapshot counter = findStreamCounter(counters, typeId, registrationId, sessionId, streamId, channel);
            if (counter != null)
            {
                return counter;
            }

            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException("Timed out waiting for stream counter typeId=" + typeId +
                    " registrationId=" + registrationId);
            }

            sleepQuietly(10);
        }
    }

    private static CounterSnapshot awaitChannelStatusCounter(
        final CountersReader counters,
        final int typeId,
        final int counterId,
        final long registrationId,
        final String channel)
    {
        if (counterId == ChannelEndpointStatus.NO_ID_ALLOCATED)
        {
            throw new IllegalStateException("Channel status id was not allocated for typeId=" + typeId);
        }

        final long deadline = System.nanoTime() + TIMEOUT_NS;
        while (true)
        {
            final CounterSnapshot counter = findChannelStatusCounter(counters, typeId, counterId, registrationId, channel);
            if (counter != null)
            {
                return counter;
            }

            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException("Timed out waiting for channel-status counter typeId=" + typeId +
                    " counterId=" + counterId + " registrationId=" + registrationId);
            }

            sleepQuietly(10);
        }
    }

    private static StreamCounterSnapshot findStreamCounter(
        final CountersReader counters,
        final int typeId,
        final long registrationId,
        final int sessionId,
        final int streamId,
        final String channel)
    {
        final StreamCounterSnapshot[] result = new StreamCounterSnapshot[1];
        counters.forEach((counterId, counterTypeId, keyBuffer, label) ->
        {
            if (result[0] != null || counterTypeId != typeId)
            {
                return;
            }

            if (counters.getCounterRegistrationId(counterId) != registrationId)
            {
                return;
            }

            if (keyBuffer.getLong(StreamCounter.REGISTRATION_ID_OFFSET) != registrationId ||
                keyBuffer.getInt(StreamCounter.SESSION_ID_OFFSET) != sessionId ||
                keyBuffer.getInt(StreamCounter.STREAM_ID_OFFSET) != streamId)
            {
                return;
            }

            final int channelLength = keyBuffer.getInt(StreamCounter.CHANNEL_OFFSET);
            final String keyChannel = keyBuffer.getStringWithoutLengthAscii(
                StreamCounter.CHANNEL_OFFSET + Integer.BYTES,
                channelLength);
            if (!channel.equals(keyChannel))
            {
                return;
            }

            result[0] = new StreamCounterSnapshot(counterId, counters.getCounterValue(counterId), label);
        });
        return result[0];
    }

    private static CounterSnapshot findChannelStatusCounter(
        final CountersReader counters,
        final int typeId,
        final int counterId,
        final long registrationId,
        final String channel)
    {
        if (counters.getCounterTypeId(counterId) != typeId)
        {
            return null;
        }

        if (counters.getCounterRegistrationId(counterId) != registrationId)
        {
            return null;
        }

        final DirectBuffer keyBuffer = counters.metaDataBuffer();
        final int recordOffset = CountersReader.metaDataOffset(counterId);
        final int channelLength = keyBuffer.getInt(recordOffset + CountersReader.KEY_OFFSET);
        final String keyChannel = keyBuffer.getStringWithoutLengthAscii(
            recordOffset + CountersReader.KEY_OFFSET + Integer.BYTES,
            channelLength);
        if (!channel.equals(keyChannel))
        {
            return null;
        }

        return new CounterSnapshot(counterId, counters.getCounterValue(counterId), counters.getCounterLabel(counterId));
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

    private static class CounterSnapshot
    {
        final int counterId;
        final long value;
        final String label;

        private CounterSnapshot(final int counterId, final long value, final String label)
        {
            this.counterId = counterId;
            this.value = value;
            this.label = label;
        }
    }

    private static final class StreamCounterSnapshot extends CounterSnapshot
    {
        private StreamCounterSnapshot(final int counterId, final long value, final String label)
        {
            super(counterId, value, label);
        }
    }
}
