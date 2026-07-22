package trading;

import java.util.HashMap;
import java.util.Map;
import java.util.TreeMap;

public final class TradingOrderBook
{
    public static final String SYMBOL = "BTC_USDT";

    public enum Side { BID, ASK }

    public record Order(long orderId, Side side, long priceTicks, long quantity) {}

    public record SubmitResult(long filledQuantity, long restingQuantity) {}

    private final TreeMap<Long, Queue> bids = new TreeMap<>();
    private final TreeMap<Long, Queue> asks = new TreeMap<>();
    private final Map<Long, Order> liveOrders = new HashMap<>();

    public SubmitResult submit(final Order order)
    {
        if (order.orderId() <= 0 || order.priceTicks() <= 0 || order.quantity() <= 0)
        {
            throw new IllegalArgumentException("invalid BTC_USDT order");
        }
        if (liveOrders.containsKey(order.orderId()))
        {
            throw new IllegalArgumentException("duplicate order id: " + order.orderId());
        }

        long remaining = order.quantity();
        long filled = 0;
        final TreeMap<Long, Queue> opposite = order.side() == Side.BID ? asks : bids;

        while (remaining > 0 && !opposite.isEmpty())
        {
            final Map.Entry<Long, Queue> level = order.side() == Side.BID
                ? opposite.firstEntry()
                : opposite.lastEntry();
            final boolean crosses = order.side() == Side.BID
                ? level.getKey() <= order.priceTicks()
                : level.getKey() >= order.priceTicks();
            if (!crosses)
            {
                break;
            }

            final Queue queue = level.getValue();
            while (remaining > 0 && !queue.orders.isEmpty())
            {
                final Order resting = queue.orders.getFirst();
                final long matched = Math.min(remaining, resting.quantity());
                remaining -= matched;
                filled += matched;

                if (matched == resting.quantity())
                {
                    queue.orders.removeFirst();
                    liveOrders.remove(resting.orderId());
                }
                else
                {
                    queue.orders.removeFirst();
                    final Order reduced = new Order(
                        resting.orderId(), resting.side(), resting.priceTicks(), resting.quantity() - matched);
                    queue.orders.addFirst(reduced);
                    liveOrders.put(reduced.orderId(), reduced);
                }
            }
            if (queue.orders.isEmpty())
            {
                opposite.remove(level.getKey());
            }
        }

        if (remaining > 0)
        {
            final Order resting = new Order(order.orderId(), order.side(), order.priceTicks(), remaining);
            final TreeMap<Long, Queue> sameSide = order.side() == Side.BID ? bids : asks;
            sameSide.computeIfAbsent(order.priceTicks(), ignored -> new Queue()).orders.addLast(resting);
            liveOrders.put(resting.orderId(), resting);
        }

        return new SubmitResult(filled, remaining);
    }

    public Order bestBid()
    {
        return best(bids, true);
    }

    public Order bestAsk()
    {
        return best(asks, false);
    }

    private static Order best(final TreeMap<Long, Queue> levels, final boolean bid)
    {
        if (levels.isEmpty())
        {
            return null;
        }
        return levels.get(bid ? levels.lastKey() : levels.firstKey()).orders.getFirst();
    }

    private static final class Queue
    {
        private final java.util.LinkedList<Order> orders = new java.util.LinkedList<>();
    }
}
