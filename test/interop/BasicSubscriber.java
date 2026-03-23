import io.aeron.Aeron;
import io.aeron.Subscription;
import io.aeron.driver.MediaDriver;
import io.aeron.logbuffer.FragmentHandler;
import org.agrona.concurrent.SigInt;
import java.util.concurrent.atomic.AtomicBoolean;

public class BasicSubscriber {
    public static void main(String[] args) throws Exception {
        final String channel = "aeron:udp?endpoint=localhost:40124";
        final int streamId = 1001;
        final AtomicBoolean running = new AtomicBoolean(true);
        SigInt.register(() -> running.set(false));

        System.out.println("Launching Java Media Driver...");
        try (MediaDriver driver = MediaDriver.launchEmbedded();
             Aeron aeron = Aeron.connect(new Aeron.Context().aeronDirectoryName(driver.aeronDirectoryName()));
             Subscription sub = aeron.addSubscription(channel, streamId)) {

            System.out.println("Java Subscriber connected to " + channel);
            final int[] messagesReceived = {0};
            FragmentHandler handler = (buffer, offset, length, header) -> {
                messagesReceived[0]++;
                if (messagesReceived[0] % 10 == 0) {
                    System.out.println("Received: " + messagesReceived[0]);
                }
                if (messagesReceived[0] >= 100) {
                    running.set(false);
                }
            };

            while (running.get()) {
                int fragments = sub.poll(handler, 10);
                if (fragments == 0) {
                    Thread.sleep(10);
                }
            }
            System.out.println("Java Subscriber finished (received " + messagesReceived[0] + " messages).");
        }
    }
}
