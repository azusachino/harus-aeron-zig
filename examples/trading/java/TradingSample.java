package trading;

public final class TradingSample
{
    private TradingSample() {}

    public static void main(final String[] args)
    {
        final TradingOrderBook book = new TradingOrderBook();
        final TradingOrderBook.SubmitResult first = book.submit(
            new TradingOrderBook.Order(1, TradingOrderBook.Side.ASK, 10100, 10));
        final TradingOrderBook.SubmitResult second = book.submit(
            new TradingOrderBook.Order(2, TradingOrderBook.Side.BID, 10100, 4));

        require(first.filledQuantity() == 0 && first.restingQuantity() == 10, "ask rests");
        require(second.filledQuantity() == 4 && second.restingQuantity() == 0, "bid crosses");
        require(book.bestAsk().quantity() == 6, "ask residual is six");
        System.out.println("JAVA BTC_USDT OK filled=4 bestAsk=10100x6");
    }

    private static void require(final boolean condition, final String message)
    {
        if (!condition)
        {
            throw new AssertionError(message);
        }
    }
}
