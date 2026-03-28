import io.aeron.AeronCounters;
import io.aeron.CncFileDescriptor;
import org.agrona.DirectBuffer;
import org.agrona.IoUtil;
import org.agrona.concurrent.UnsafeBuffer;
import org.agrona.concurrent.status.CountersReader;

import java.io.File;
import java.nio.MappedByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.TimeUnit;

public final class CountersChecker
{
    private static final long TIMEOUT_NS = TimeUnit.SECONDS.toNanos(5);

    static final class CounterSnapshot
    {
        int counterId;
        int typeId;
        long registrationId;
        long value;
        String label;
        String keyStr;
    }

    public static void main(final String[] args) throws Exception
    {
        final String aeronDir = System.getProperty("aeron.dir", "/dev/shm/aeron");
        final File cncFile = new File(aeronDir, CncFileDescriptor.CNC_FILE);

        System.out.println("CountersChecker: Starting");
        System.out.println("  aeron.dir=" + aeronDir);
        System.out.println("  cnc.dat=" + cncFile.getAbsolutePath());

        // Wait for CnC file to be available
        awaitCncFile(cncFile);

        // Memory-map the CnC file
        final MappedByteBuffer cncBuffer = IoUtil.mapExistingFile(cncFile, "cnc");
        final DirectBuffer cncMetaDataBuffer = CncFileDescriptor.createMetaDataBuffer(cncBuffer);

        final UnsafeBuffer countersMetaData = CncFileDescriptor.createCountersMetaDataBuffer(cncBuffer, cncMetaDataBuffer);
        final UnsafeBuffer countersValues = CncFileDescriptor.createCountersValuesBuffer(cncBuffer, cncMetaDataBuffer);

        final CountersReader reader = new CountersReader(countersMetaData, countersValues, StandardCharsets.US_ASCII);

        // Wait for InteropSmoke to signal that counters are populated
        System.out.println("CountersChecker: waiting for smoke-ready signal...");
        final File smokeReady = new File("/tmp/smoke-ready");
        final long readyDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60);
        while (!smokeReady.exists())
        {
            if (System.nanoTime() > readyDeadline)
            {
                throw new IllegalStateException("Timed out waiting for InteropSmoke ready signal");
            }
            Thread.sleep(100);
        }
        System.out.println("CountersChecker: smoke-ready signal received");

        // Poll until minimum counter types are present
        final Set<Integer> requiredTypes = Set.of(
            AeronCounters.DRIVER_PUBLISHER_LIMIT_TYPE_ID,
            AeronCounters.DRIVER_SENDER_POSITION_TYPE_ID,
            AeronCounters.DRIVER_RECEIVER_HWM_TYPE_ID,
            AeronCounters.DRIVER_SUBSCRIBER_POSITION_TYPE_ID,
            AeronCounters.DRIVER_SEND_CHANNEL_STATUS_TYPE_ID,
            AeronCounters.DRIVER_RECEIVE_CHANNEL_STATUS_TYPE_ID);

        final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
        Set<Integer> typesFound;
        int iterations = 0;
        do
        {
            typesFound = new HashSet<>();
            final Set<Integer> currentTypes = typesFound;
            reader.forEach((counterId, typeId, keyBuffer, label) ->
            {
                currentTypes.add(typeId);
            });

            if (currentTypes.containsAll(requiredTypes))
            {
                break;
            }

            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException(
                    "Timed out waiting for required counter types. Found: " + currentTypes + " Required: " + requiredTypes);
            }

            Thread.sleep(100);
            iterations++;
        }
        while (true);

        System.out.println("All required counter types detected, starting validation...");

        try
        {
            // Collect all allocated counters
            final List<CounterSnapshot> snapshots = new ArrayList<>();
            final Set<Integer> allTypesFound = new HashSet<>(typesFound);

            reader.forEach((counterId, typeId, keyBuffer, label) ->
            {
                allTypesFound.add(typeId);
                final CounterSnapshot snap = new CounterSnapshot();
                snap.counterId = counterId;
                snap.typeId = typeId;
                snap.value = reader.getCounterValue(counterId);
                snap.label = label;
                snap.registrationId = countersValues.getLong(CountersReader.counterOffset(counterId) + 8);
                snap.keyStr = extractKeyString(keyBuffer, typeId);

                snapshots.add(snap);
            });
            typesFound = allTypesFound;

            System.out.println();
            System.out.println("Counters collected: " + snapshots.size());

            // Validate each counter
            for (final CounterSnapshot snap : snapshots)
            {
                validateCounter(snap, reader);
            }

            // Validate lookup for at least one stream counter and one channel-status counter
            Integer streamCounterId = null;
            Integer channelStatusCounterId = null;

            for (final CounterSnapshot snap : snapshots)
            {
                if (streamCounterId == null && snap.typeId >= 1 && snap.typeId <= 5)
                {
                    streamCounterId = snap.counterId;
                }
                if (channelStatusCounterId == null && (snap.typeId == 6 || snap.typeId == 7))
                {
                    channelStatusCounterId = snap.counterId;
                }
            }

            if (streamCounterId != null)
            {
                validateLookup(reader, streamCounterId, countersValues, "stream counter");
            }

            if (channelStatusCounterId != null)
            {
                validateLookup(reader, channelStatusCounterId, countersValues, "channel-status counter");
            }

            System.out.println();
            System.out.println("All validations passed!");
            System.out.println("Types found: " + typesFound);
            System.out.println("Total counters validated: " + snapshots.size());
            System.out.println("CheckersOK");
        }
        finally
        {
            new File("/tmp/checker-done").createNewFile();
        }
    }

    private static void awaitCncFile(final File cncFile)
    {
        final long deadline = System.nanoTime() + TIMEOUT_NS;

        while (!cncFile.exists())
        {
            if (System.nanoTime() > deadline)
            {
                throw new IllegalStateException(
                    "Timed out waiting for CnC file: " + cncFile.getAbsolutePath());
            }

            try
            {
                Thread.sleep(100);
            }
            catch (final InterruptedException e)
            {
                Thread.currentThread().interrupt();
                throw new IllegalStateException("Interrupted waiting for CnC file", e);
            }
        }

        System.out.println("CnC file found");
    }

    private static void validateCounter(final CounterSnapshot snap, final CountersReader reader)
    {
        final int typeId = snap.typeId;

        // Type ID validation
        if (typeId == 0)
        {
            System.out.println("WARNING: counter " + snap.counterId + " has typeId=0 (unexpected for allocated record)");
            return;
        }

        if (typeId != AeronCounters.DRIVER_PUBLISHER_LIMIT_TYPE_ID &&
            typeId != AeronCounters.DRIVER_SENDER_POSITION_TYPE_ID &&
            typeId != AeronCounters.DRIVER_RECEIVER_HWM_TYPE_ID &&
            typeId != AeronCounters.DRIVER_SUBSCRIBER_POSITION_TYPE_ID &&
            typeId != AeronCounters.DRIVER_RECEIVER_POS_TYPE_ID &&
            typeId != AeronCounters.DRIVER_SEND_CHANNEL_STATUS_TYPE_ID &&
            typeId != AeronCounters.DRIVER_RECEIVE_CHANNEL_STATUS_TYPE_ID)
        {
            throw new IllegalStateException(
                "Unknown counter type: " + typeId + " for counter " + snap.counterId);
        }

        // Registration ID validation for stream counters
        if (typeId >= 1 && typeId <= 5)
        {
            if (snap.registrationId == 0)
            {
                throw new IllegalStateException(
                    "Stream counter " + snap.counterId + " has zero registration ID");
            }
        }

        // Value sanity checks
        if (typeId >= 1 && typeId <= 5)
        {
            if (snap.value < 0)
            {
                throw new IllegalStateException(
                    "Position counter " + snap.counterId + " has negative value: " + snap.value);
            }
        }

        if (typeId == AeronCounters.DRIVER_SEND_CHANNEL_STATUS_TYPE_ID ||
            typeId == AeronCounters.DRIVER_RECEIVE_CHANNEL_STATUS_TYPE_ID)
        {
            // ChannelEndpointStatus.ACTIVE == 1
            if (snap.value != 1)
            {
                throw new IllegalStateException(
                    "Channel-status counter " + snap.counterId + " expected value 1, got: " + snap.value);
            }
        }
    }

    private static void validateLookup(final CountersReader reader, final int counterId, final DirectBuffer countersValues, final String desc)
    {
        final int typeId = reader.getCounterTypeId(counterId);
        final long registrationId = countersValues.getLong(CountersReader.counterOffset(counterId) + 8);
        final long value = reader.getCounterValue(counterId);

        if (typeId == 0)
        {
            throw new IllegalStateException(
                "Failed to look up " + desc + " " + counterId + ": type ID is 0");
        }

        System.out.println("Lookup validated: " + desc + " counterId=" + counterId +
            " typeId=" + typeId + " registrationId=" + registrationId + " value=" + value);
    }

    private static String extractKeyString(final DirectBuffer keyBuffer, final int typeId)
    {
        if (keyBuffer.capacity() == 0)
        {
            return "(empty)";
        }

        try
        {
            final StringBuilder sb = new StringBuilder();

            if (typeId >= 1 && typeId <= 5)
            {
                // Stream counter: registration_id (8) + session_id (4) + stream_id (4) + channel_length (4) + channel
                if (keyBuffer.capacity() >= 20)
                {
                    final long registrationId = keyBuffer.getLong(0);
                    final int sessionId = keyBuffer.getInt(8);
                    final int streamId = keyBuffer.getInt(12);
                    final int channelLength = keyBuffer.getInt(16);

                    sb.append("reg=").append(registrationId)
                        .append(" session=").append(sessionId)
                        .append(" stream=").append(streamId)
                        .append(" channel_len=").append(channelLength);

                    if (channelLength > 0 && keyBuffer.capacity() >= 20 + channelLength)
                    {
                        final byte[] channelBytes = new byte[channelLength];
                        keyBuffer.getBytes(20, channelBytes);
                        sb.append(" channel=").append(new String(channelBytes));
                    }
                }
            }
            else if (typeId == 6 || typeId == 7)
            {
                // Channel-status: channel_length (4) + channel
                if (keyBuffer.capacity() >= 4)
                {
                    final int channelLength = keyBuffer.getInt(0);
                    sb.append("channel_len=").append(channelLength);

                    if (channelLength > 0 && keyBuffer.capacity() >= 4 + channelLength)
                    {
                        final byte[] channelBytes = new byte[channelLength];
                        keyBuffer.getBytes(4, channelBytes);
                        sb.append(" channel=").append(new String(channelBytes));
                    }
                }
            }

            return sb.toString();
        }
        catch (final Exception e)
        {
            return "(parse error: " + e.getMessage() + ")";
        }
    }
}
