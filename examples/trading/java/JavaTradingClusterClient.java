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
        final EgressListener listener = (sessionId, timestamp, buffer, offset, length, header) ->
        {
            final String response = buffer.getStringWithoutLengthAscii(offset, length);
            if (!response.startsWith("BTC_USDT|"))
            {
                throw new IllegalStateException("unexpected response: " + response);
            }
            responses.incrementAndGet();
            System.out.println("JAVA_CLIENT " + response);
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
            final String[] orders = {
                "BTC_USDT|1|ASK|10100|10",
                "BTC_USDT|2|BID|10100|4",
                "BTC_USDT|3|BID|10050|8",
            };
            for (final String order : orders)
            {
                final ExpandableArrayBuffer buffer = new ExpandableArrayBuffer(order.length());
                final int length = buffer.putStringWithoutLengthAscii(0, order);
                while (cluster.offer(buffer, 0, length) < 0)
                {
                    Thread.yield();
                }
            }

            final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30);
            while (responses.get() < orders.length && System.nanoTime() < deadline)
            {
                if (cluster.pollEgress() == 0)
                {
                    Thread.yield();
                }
            }
            if (responses.get() != orders.length)
            {
                throw new IllegalStateException("timed out waiting for BTC_USDT responses");
            }
            System.out.println("JAVA_CLUSTER_CLIENT_OK responses=" + responses.get());
        }
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
