package trading;

public final class TradingOrderBookTest
{
    private TradingOrderBookTest() {}

    public static void main(final String[] args)
    {
        happyPath();
        evilPath();
        edgePath();
        System.out.println("JAVA BTC_USDT TESTS OK happy=1 evil=1 edge=1");
    }

    private static void happyPath()
    {
        final TradingOrderBook book = new TradingOrderBook();
        book.submit(new TradingOrderBook.Order(1, TradingOrderBook.Side.ASK, 100, 5));
        final TradingOrderBook.SubmitResult result = book.submit(
            new TradingOrderBook.Order(2, TradingOrderBook.Side.BID, 100, 3));
        require(result.filledQuantity() == 3, "happy filled quantity");
        require(book.bestAsk().quantity() == 2, "happy residual");
    }

    private static void evilPath()
    {
        final TradingOrderBook book = new TradingOrderBook();
        expectFailure(() -> book.submit(new TradingOrderBook.Order(1, TradingOrderBook.Side.BID, 0, 1)));
        book.submit(new TradingOrderBook.Order(1, TradingOrderBook.Side.BID, 100, 1));
        expectFailure(() -> book.submit(new TradingOrderBook.Order(1, TradingOrderBook.Side.ASK, 99, 1)));
    }

    private static void edgePath()
    {
        final TradingOrderBook book = new TradingOrderBook();
        final TradingOrderBook.SubmitResult result = book.submit(
            new TradingOrderBook.Order(7, TradingOrderBook.Side.BID, 99, 2));
        require(result.filledQuantity() == 0 && result.restingQuantity() == 2, "edge resting order");
        require(book.bestAsk() == null && book.bestBid().priceTicks() == 99, "edge book sides");

        book.submit(new TradingOrderBook.Order(8, TradingOrderBook.Side.ASK, 100, 1));
        book.submit(new TradingOrderBook.Order(9, TradingOrderBook.Side.ASK, 100, 1));
        book.submit(new TradingOrderBook.Order(10, TradingOrderBook.Side.BID, 100, 1));
        require(book.bestAsk().orderId() == 9, "equal-price FIFO");
    }

    private static void expectFailure(final Runnable action)
    {
        try
        {
            action.run();
            throw new AssertionError("expected order rejection");
        }
        catch (final IllegalArgumentException expected)
        {
            // expected
        }
    }

    private static void require(final boolean condition, final String message)
    {
        if (!condition)
        {
            throw new AssertionError(message);
        }
    }
}
