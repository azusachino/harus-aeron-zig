import io.aeron.Aeron;
import io.aeron.Subscription;

public final class InteropSmoke
{
    private static final String CHANNEL =
        System.getProperty("aeron.sample.channel", "aeron:udp?endpoint=localhost:20121");
    private static final int STREAM_ID = Integer.getInteger("aeron.sample.streamId", 1001);

    private InteropSmoke()
    {
    }

    public static void main(final String[] args)
    {
        System.out.println("Subscribing to " + CHANNEL + " on stream id " + STREAM_ID);

        final Aeron.Context ctx = new Aeron.Context();
        try (Aeron aeron = Aeron.connect(ctx);
            Subscription subscription = aeron.addSubscription(CHANNEL, STREAM_ID))
        {
            System.out.println(
                "Subscription ready: registrationId=" + subscription.registrationId() +
                ", channelStatusId=" + subscription.channelStatusId());
        }

        System.out.println("Smoke OK");
    }
}
