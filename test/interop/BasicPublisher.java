import io.aeron.Aeron;
import io.aeron.Publication;
import io.aeron.driver.MediaDriver;
import org.agrona.concurrent.UnsafeBuffer;
import java.nio.ByteBuffer;

public class BasicPublisher {
    public static void main(String[] args) throws Exception {
        final String channel = "aeron:udp?endpoint=localhost:40124";
        final int streamId = 1001;

        System.out.println("Launching Java Media Driver...");
        try (MediaDriver driver = MediaDriver.launchEmbedded();
             Aeron aeron = Aeron.connect(new Aeron.Context().aeronDirectoryName(driver.aeronDirectoryName()));
             Publication pub = aeron.addPublication(channel, streamId)) {

            System.out.println("Java Publisher connected to " + channel);
            UnsafeBuffer buf = new UnsafeBuffer(ByteBuffer.allocateDirect(128));
            
            for (int i = 0; i < 100; i++) {
                String msg = "Hello Aeron " + i;
                buf.putStringWithoutLengthUtf8(0, msg);
                
                while (pub.offer(buf, 0, msg.length()) < 0) {
                    Thread.onSpinWait();
                }
                if (i % 10 == 0) System.out.println("Sent: " + i);
            }
            System.out.println("Java Publisher finished sending 100 messages.");
            Thread.sleep(1000);
        }
    }
}
