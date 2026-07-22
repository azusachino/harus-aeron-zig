package trading;

import io.aeron.Aeron;
import io.aeron.ConcurrentPublication;
import io.aeron.Image;
import io.aeron.Subscription;
import io.aeron.driver.MediaDriver;
import io.aeron.cluster.codecs.BooleanType;
import io.aeron.cluster.codecs.AppendPositionEncoder;
import io.aeron.cluster.codecs.CatchupPositionEncoder;
import io.aeron.cluster.codecs.CommitPositionEncoder;
import io.aeron.cluster.codecs.MessageHeaderEncoder;
import io.aeron.cluster.codecs.RequestVoteEncoder;
import io.aeron.cluster.codecs.StopCatchupEncoder;
import io.aeron.cluster.codecs.VoteDecoder;
import org.agrona.ExpandableArrayBuffer;

import java.util.concurrent.TimeUnit;

/** Live Java-generated-SBE to Zig consensus adapter probe. */
public final class JavaConsensusInteropProbe
{
    private JavaConsensusInteropProbe() {}

    public static void main(final String[] args)
    {
        final String aeronDir = env("AERON_DIR", "/dev/shm/aeron");
        final String target = required("CONSENSUS_ENDPOINT");
        final int responsePort = Integer.parseInt(env("RESPONSE_PORT", "9023"));
        final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20);

        try (MediaDriver driver = MediaDriver.launch(new MediaDriver.Context()
                .aeronDirectoryName(aeronDir)
                .dirDeleteOnStart(true));
            Aeron aeron = Aeron.connect(new Aeron.Context().aeronDirectoryName(aeronDir)))
        {
            final ConcurrentPublication publication = aeron.addPublication(
                "aeron:udp?endpoint=" + target, 108);
            final Subscription subscription = aeron.addSubscription(
                "aeron:udp?endpoint=0.0.0.0:" + responsePort, 108);
            final ExpandableArrayBuffer request = new ExpandableArrayBuffer(256);
            final MessageHeaderEncoder header = new MessageHeaderEncoder();
            new RequestVoteEncoder()
                .wrapAndApplyHeader(request, 0, header)
                .logLeadershipTermId(0)
                .logPosition(0)
                .candidateTermId(1)
                .candidateMemberId(0)
                .protocolVersion(15);

            while (!publication.isConnected() && System.nanoTime() < deadline)
            {
                Thread.yield();
            }
            while (publication.offer(request, 0, 40) < 0 && System.nanoTime() < deadline)
            {
                Thread.yield();
            }

            final VoteDecoder vote = new VoteDecoder();
            final boolean[] received = { false };
            while (!received[0] && System.nanoTime() < deadline)
            {
                subscription.poll((buffer, offset, length, image) ->
                {
                    vote.wrap(
                        buffer,
                        offset + 8,
                        buffer.getShort(offset),
                        buffer.getShort(offset + 6));
                    if (vote.candidateMemberId() == 0 && vote.followerMemberId() == 2 &&
                        vote.vote() == BooleanType.TRUE)
                    {
                        received[0] = true;
                    }
                }, 10);
                Thread.yield();
            }

            if (!received[0])
            {
                throw new IllegalStateException("timed out waiting for Zig Vote");
            }

            final AppendPositionEncoder append = new AppendPositionEncoder()
                .wrapAndApplyHeader(request, 0, header)
                .leadershipTermId(1)
                .logPosition(128)
                .followerMemberId(2)
                .flags((short)1);
            offer(publication, request, MessageHeaderEncoder.ENCODED_LENGTH + append.encodedLength(), deadline);

            final CommitPositionEncoder commit = new CommitPositionEncoder()
                .wrapAndApplyHeader(request, 0, header)
                .leadershipTermId(1)
                .logPosition(128)
                .leaderMemberId(0);
            offer(publication, request, MessageHeaderEncoder.ENCODED_LENGTH + commit.encodedLength(), deadline);

            final CatchupPositionEncoder catchup = new CatchupPositionEncoder()
                .wrapAndApplyHeader(request, 0, header)
                .leadershipTermId(1)
                .logPosition(64)
                .followerMemberId(2)
                .catchupEndpoint("aeron:udp?endpoint=java-probe:9024");
            offer(publication, request, MessageHeaderEncoder.ENCODED_LENGTH + catchup.encodedLength(), deadline);

            final StopCatchupEncoder stop = new StopCatchupEncoder()
                .wrapAndApplyHeader(request, 0, header)
                .leadershipTermId(1)
                .followerMemberId(2);
            offer(publication, request, MessageHeaderEncoder.ENCODED_LENGTH + stop.encodedLength(), deadline);

            System.out.println("JAVA_ZIG_CONSENSUS_INTEROP_OK templates=52,54,55,56,57 vote=true");
        }
    }

    private static void offer(
        final ConcurrentPublication publication,
        final ExpandableArrayBuffer buffer,
        final int length,
        final long deadline)
    {
        while (publication.offer(buffer, 0, length) < 0 && System.nanoTime() < deadline)
        {
            Thread.yield();
        }
        if (System.nanoTime() >= deadline)
        {
            throw new IllegalStateException("timed out offering consensus message");
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

    private static String env(final String name, final String fallback)
    {
        final String value = System.getenv(name);
        return value == null || value.isBlank() ? fallback : value;
    }
}
