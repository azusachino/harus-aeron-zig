# BTC_USDT cluster samples

These samples model one instrument only: `BTC_USDT`.

The order event shape is intentionally small and language-neutral:

```text
BTC_USDT|order_id|side|price_ticks|quantity
```

`side` is `BID` or `ASK`. Prices and quantities are positive integer ticks,
so the example has no floating-point behavior to hide in cross-language tests.

The intended deployments are three-member clusters, each with external
clients:

- `zig`: three Zig cluster members plus Zig and Java clients.
- `java`: three upstream Java Aeron Cluster members plus Java and Zig clients.
- `mixed`: two Java members and one Zig member plus both client languages.

The Java files now include a working three-member Aeron Cluster baseline and
client smoke. Zig and mixed remain blocked until their three-process cluster
topologies and client failover assertions exist. See
`docs/specs/2026-07-19-btc-usdt-cluster-sample.md` for the acceptance matrix.

Matching rules are deterministic:

1. A bid crosses the lowest resting ask at or below its limit price.
2. An ask crosses the highest resting bid at or above its limit price.
3. Equal-price orders are matched in arrival order.
4. A residual quantity rests on the book.
5. Invalid orders and duplicate order IDs are rejected.
