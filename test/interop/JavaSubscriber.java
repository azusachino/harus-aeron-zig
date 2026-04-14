public class JavaSubscriber {
    public static void main(String[] args) throws Exception {
        String stub = System.getenv("AERON_INTEROP_STUB");
        if ("1".equals(stub)) {
            System.out.println("java-subscriber: stub mode — exit 0");
            return;
        }
        String channel = System.getenv().getOrDefault("AERON_CHANNEL", "aeron:udp?endpoint=localhost:20121");
        int expected = Integer.parseInt(System.getenv().getOrDefault("AERON_MSG_COUNT", "10"));
        System.out.printf("java-subscriber: waiting for %d messages on %s%n", expected, channel);
        long deadline = System.currentTimeMillis() + 30_000;
        int received = 0;
        while (received < expected) {
            if (System.currentTimeMillis() > deadline) {
                System.err.printf("java-subscriber: timeout — received %d/%d%n", received, expected);
                System.exit(1);
            }
            Thread.sleep(10);
        }
        System.out.printf("java-subscriber: received %d messages — OK%n", received);
    }
}
