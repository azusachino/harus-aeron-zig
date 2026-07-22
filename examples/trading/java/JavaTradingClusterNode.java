package trading;

import io.aeron.archive.Archive;
import io.aeron.archive.ArchiveThreadingMode;
import io.aeron.cluster.ClusteredMediaDriver;
import io.aeron.cluster.ConsensusModule;
import io.aeron.cluster.service.ClusteredServiceContainer;
import io.aeron.driver.MediaDriver;
import io.aeron.driver.ThreadingMode;
import org.agrona.CloseHelper;

import java.io.File;

public final class JavaTradingClusterNode
{
    private JavaTradingClusterNode() {}

    public static void main(final String[] args)
    {
        final int memberId = Integer.parseInt(required("CLUSTER_MEMBER_ID"));
        final String aeronDir = env("AERON_DIR", "/tmp/btc-usdt/aeron-" + memberId);
        final String archiveDir = env("ARCHIVE_DIR", "/tmp/btc-usdt/archive-" + memberId);
        final String clusterDir = env("CLUSTER_DIR", "/tmp/btc-usdt/cluster-" + memberId);
        final String members = required("CLUSTER_MEMBERS");
        final boolean reset = Boolean.parseBoolean(env("RESET_CLUSTER", "true"));

        ClusteredMediaDriver driver = null;
        ClusteredServiceContainer service = null;
        try
        {
            final MediaDriver.Context mediaContext = new MediaDriver.Context()
                .aeronDirectoryName(aeronDir)
                .threadingMode(ThreadingMode.SHARED)
                .termBufferSparseFile(true)
                .dirDeleteOnStart(reset);

            final Archive.Context archiveContext = new Archive.Context()
                .aeronDirectoryName(aeronDir)
                .archiveDir(new File(archiveDir))
                .controlChannel("aeron:udp?endpoint=0.0.0.0:" + (8020 + memberId))
                .replicationChannel("aeron:udp?endpoint=0.0.0.0:" + (8030 + memberId))
                .threadingMode(ArchiveThreadingMode.SHARED)
                .recordingEventsEnabled(false)
                .deleteArchiveOnStart(reset);

            final ConsensusModule.Context consensusContext = new ConsensusModule.Context()
                .aeronDirectoryName(aeronDir)
                .clusterMemberId(memberId)
                .clusterMembers(members)
                .clusterDir(new File(clusterDir))
                .ingressChannel("aeron:udp")
                .logChannel("aeron:udp")
                .replicationChannel("aeron:udp")
                .deleteDirOnStart(reset);

            driver = ClusteredMediaDriver.launch(mediaContext, archiveContext, consensusContext);
            service = ClusteredServiceContainer.launch(new ClusteredServiceContainer.Context()
                .aeronDirectoryName(aeronDir)
                .clusteredService(new BtcUsdtClusterService()));

            System.out.println("JAVA_CLUSTER_READY member=" + memberId);
            Thread.currentThread().join();
        }
        catch (final InterruptedException ex)
        {
            Thread.currentThread().interrupt();
        }
        finally
        {
            CloseHelper.closeAll(service, driver);
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
