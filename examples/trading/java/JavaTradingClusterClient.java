package trading;

import io.aeron.cluster.client.AeronCluster;
import io.aeron.cluster.client.EgressListener;
import io.aeron.driver.MediaDriver;
import org.agrona.ExpandableArrayBuffer;

import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public final class JavaTradingClusterClient
{
    private JavaTradingClusterClient() {}

    public static void main(final String[] args)
    {
        final AtomicInteger responses = new AtomicInteger();
        final boolean quiet = "1".equals(System.getenv("QUIET"));
        final EgressListener listener = (sessionId, timestamp, buffer, offset, length, header) ->
        {
            final String response = buffer.getStringWithoutLengthAscii(offset, length);
            if (!response.startsWith("BTC_USDT|"))
            {
                throw new IllegalStateException("unexpected response: " + response);
            }
            responses.incrementAndGet();
            if (!quiet)
            {
                System.out.println("JAVA_CLIENT " + response);
            }
        };

        try (MediaDriver driver = MediaDriver.launch(new MediaDriver.Context()
                .aeronDirectoryName("/dev/shm/aeron")
                .dirDeleteOnStart(true));
            AeronCluster cluster = AeronCluster.connect(new AeronCluster.Context()
            .aeronDirectoryName("/dev/shm/aeron")
            .messageTimeoutNs(TimeUnit.SECONDS.toNanos(30))
            .egressListener(listener)
            .ingressChannel("aeron:udp")
            .ingressEndpoints(required("INGRESS_ENDPOINTS"))
            .egressChannel("aeron:udp?endpoint=java-client:0")))
        {
            final int orderCount = envInt("ORDER_COUNT", 3);
            if (orderCount <= 0)
            {
                throw new IllegalArgumentException("ORDER_COUNT must be positive");
            }
            for (int index = 0; index < orderCount; index++)
            {
                final long orderId = index + 1L;
                final String side = index % 2 == 0 ? "ASK" : "BID";
                final long price = index % 2 == 0 ? 10100 : 10050;
                final long quantity = index % 2 == 0 ? 10 : 4;
                final String order = "BTC_USDT|" + orderId + "|" + side + "|" + price + "|" + quantity;
                final ExpandableArrayBuffer buffer = new ExpandableArrayBuffer(order.length());
                final int length = buffer.putStringWithoutLengthAscii(0, order);
                while (cluster.offer(buffer, 0, length) < 0)
                {
                    Thread.yield();
                }
            }

            final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30);
            while (responses.get() < orderCount && System.nanoTime() < deadline)
            {
                if (cluster.pollEgress() == 0)
                {
                    Thread.yield();
                }
            }
            if (responses.get() != orderCount)
            {
                throw new IllegalStateException("timed out waiting for BTC_USDT responses");
            }
            System.out.println("JAVA_CLUSTER_CLIENT_OK responses=" + responses.get());
            final long holdOpenMs = envLong("HOLD_OPEN_MS", 0);
            if (holdOpenMs > 0)
            {
                final long holdDeadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(holdOpenMs);
                while (System.nanoTime() < holdDeadline)
                {
                    if (cluster.pollEgress() == 0)
                    {
                        Thread.yield();
                    }
                }
            }
        }
    }

    private static int envInt(final String name, final int fallback)
    {
        final String value = System.getenv(name);
        return value == null ? fallback : Integer.parseInt(value);
    }

    private static long envLong(final String name, final long fallback)
    {
        final String value = System.getenv(name);
        return value == null ? fallback : Long.parseLong(value);
    }

    private static String required(final String name)
    {
        final String value = System.getenv(name);
        if (value == null || value.isBlank())
        {
            throw new IllegalArgumentException("missing environment variable: " + name);
        }
        return value;
    }
}
