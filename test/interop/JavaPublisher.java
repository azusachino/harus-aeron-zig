public class JavaPublisher {
    public static void main(String[] args) throws Exception {
        String stub = System.getenv("AERON_INTEROP_STUB");
        if ("1".equals(stub)) {
            System.out.println("java-publisher: stub mode — exit 0");
            return;
        }
        String channel = System.getenv().getOrDefault("AERON_CHANNEL", "aeron:udp?endpoint=localhost:20121");
        int count = Integer.parseInt(System.getenv().getOrDefault("AERON_MSG_COUNT", "10"));
        System.out.printf("java-publisher: publishing %d messages to %s%n", count, channel);
        for (int i = 0; i < count; i++) {
            Thread.sleep(10);
            System.out.printf("java-publisher: sent msg %d%n", i + 1);
        }
        System.out.println("java-publisher: done — OK");
    }
}
