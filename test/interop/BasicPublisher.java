import io.aeron.Aeron;
import io.aeron.Publication;
import io.aeron.driver.MediaDriver;
import org.agrona.concurrent.UnsafeBuffer;
import java.nio.ByteBuffer;

public class BasicPublisher {
    public static void main(String[] args) throws Exception {
        final String channel = "aeron:udp?endpoint=localhost:40123";
        final int streamId = 1001;

        System.out.println("Launching Java Media Driver...");
        try (MediaDriver driver = MediaDriver.launchEmbedded();
             Aeron aeron = Aeron.connect(new Aeron.Context().aeronDirectoryName(driver.aeronDirectoryName()));
             Publication pub = aeron.addPublication(channel, streamId)) {

            System.out.println("Java Publisher connected to " + channel);
            UnsafeBuffer buf = new UnsafeBuffer(ByteBuffer.allocateDirect(256));
            
            for (int i = 0; i < 10; i++) {
                String msg = "message-" + i;
                buf.putStringWithoutLengthAscii(0, msg);
                
                System.out.println("Offering: " + msg);
                while (pub.offer(buf, 0, msg.length()) < 0) {
                    Thread.onSpinWait();
                }
                Thread.sleep(100);
            }
            System.out.println("Java Publisher finished sending 10 messages.");
        }
    }
}
