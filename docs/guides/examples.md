# Examples and Scenario Tests

The examples are executable validation fixtures for the unreleased 0.9 line. Build
all of them with `make examples`.

## Progression

| Example | Boundary | Evidence |
| --- | --- | --- |
| basic-publisher / basic-subscriber | Embedded MediaDriver and client API | Compile fixture; run against a shared Aeron directory |
| throughput-example | IPC data path and counters | Configurable short benchmark |
| cluster-demo | Election, sessions, replication, and failover APIs | In-process cluster simulation |
| trading-order-book | Cluster log plus deterministic matching state | Executable happy/evil/edge tests |

The trading example is intentionally explicit about its current boundary: it uses
the real cluster and log modules but keeps nodes in one process. It is not yet a
claim of a multi-process UDP cluster. That is the next integration stage.

Run the order-book scenario tests with `make test-examples`.

The tests cover:

- happy: crossing bid/ask orders execute at the available quantity;
- evil: zero-priced, zero-sized, and duplicate orders are rejected;
- edge: non-crossing orders remain on the correct book side.

The intended next example is a multi-process trading topology:

    market-data publisher -> Aeron ingress -> cluster leader
                                          -> replicated order log
                                          -> follower order books
                                          -> execution/reporting publication

That topology needs real UDP endpoints, process lifecycle control, snapshot/restart
coverage, and failure injection before it should be described as a working cluster.
