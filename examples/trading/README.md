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
client smoke. The Java cluster and clients intentionally run in separate Compose
projects: `docker-compose.java-cluster.yml` owns the long-lived nodes and creates
the shared `aeron-trading` network; `docker-compose.java.yml` owns disposable
Java/Zig clients and joins that external network. This prevents a fast client
exit from tearing down the cluster while another client is still connecting or
draining responses. The Java topology can also exercise the Zig client against a
real Java cluster, including the follower-to-leader redirect. Zig now has a
real three-process topology and both client-language smokes. It wires peer
publications and heartbeat/order frames, and the source-aware receiver path
passes the three-member failover smoke: after node 0 stops, node 1 becomes
leader, node 2 follows node 1's heartbeat, and failover orders are observed on
node 2. Each member now records accepted orders into a real Aeron Archive
recording under `/data/archive` (catalog + segmented `.dat` files) and replays
it before readiness; a restart proof restored six orders on node 1
(`ZIG_CLUSTER_REPLAY ... orders=6`). Members also take periodic Archive-backed
snapshots of book + log state so a restart can skip straight past
already-snapshotted order recordings instead of replaying from the beginning.
Log replication between members (append/commit position tracking and gap
retransmission) is also wired over the internal channel; this is durable
sample replay and replication, not full Raft/consensus parity. Mixed now has a
canonical two-Java/one-Zig consensus smoke: the Zig member receives Java
RequestVote, returns Vote, and consumes NewLeadershipTerm, AppendPosition,
CommitPosition, CatchupPosition, and StopCatchup. The follower now emits a
Java-compatible `AppendPosition` at `position=0`, after which the Java leader
delivers the normal log stream. Both client languages submit orders through the
Java leader. The Zig member now also subscribes to Java's
log stream 100, decodes and journals received SBE log frames at
`/data/mixed-log.bin`, and prints BTC_USDT application payloads. Full mixed
parity still requires Zig service application, catchup/archive, ingress
ownership, and restart/replay behavior; the exact SBE/member-protocol boundary
is recorded in
`docs/investigations/2026-07-19-mixed-cluster-boundary.md`.
See
`docs/specs/2026-07-19-btc-usdt-cluster-sample.md` for the acceptance matrix.

The direct Java-generated consensus transport gate is:

```bash
COMPOSE=podman-compose podman-compose -p aeron-consensus-codec-proof \
  -f deploy/trading/docker-compose.consensus-probe.yml \
  up --build --abort-on-container-exit --exit-code-from java-probe
```

It reports `JAVA_ZIG_CONSENSUS_INTEROP_OK templates=52,54,55,56,57` and the
Zig member logs the decoded append/commit/catchup/stop state. This proves the
member-control transport only; it is not replicated log or Archive parity.

The mixed log ingress and restart proof is reproducible with:

```bash
TRADING_PROJECT_SUFFIX=mixed-log-proof-run TRADING_SOAK_MESSAGES=3 \
  uv run scripts/trading.py mixed-log-proof --mode mixed
```

The runner submits orders from both clients, recreates the Zig member without
removing its named volume, and requires the persisted log-entry count to cover
both clients' orders. This proves Java log-frame ingress and local journal
survival, not ClusteredService replay, catchup-image serving, Archive replay,
or snapshot compatibility. A true Java Archive catchup replay remains a
separate, currently unproven gate.

Run the baseline tests with `uv run scripts/trading.py test --mode java` and
run the sustained Java-cluster smoke with:

```bash
uv run scripts/trading.py soak --mode java
```

The pure-Zig journal/restart proof is reproducible with the same runner:

```bash
TRADING_SOAK_MESSAGES=3 uv run scripts/trading.py replay-proof --mode zig
```

It submits three orders from each client, restarts `zig-node-1` without
removing its named volume, asserts that six journal records are replayed, and
then tears down both Compose projects.

Exercise the process-boundary Zig topology with the same runner:

```bash
TRADING_PROJECT_SUFFIX=zig-smoke uv run scripts/trading.py soak --mode zig
```

Exercise the mixed consensus/client smoke:

```bash
TRADING_PROJECT_SUFFIX=mixed-smoke uv run scripts/trading.py soak --mode mixed
```

The 2026-07-19 three-order Zig-topology smoke passed through that runner with
both clients: Java `responses=3` and Zig `responses=3`. The Zig client first
redirected past non-leader members, then completed against member 0. Multiple
active client sessions are supported; each response publication is retained
by its cluster session rather than sharing one global egress route.

`soak` clears stale client containers, builds the Zig examples as
`ReleaseFast`, starts the Java cluster as an independent detached Compose
project, and runs both clients in a second project. The cluster remains alive
after the clients exit; `down` tears down both projects. The default is 500
orders; `TRADING_SOAK_MESSAGES` changes it and
`TRADING_SOAK_START_DELAY_MS` controls the client startup delay (default
5,000 ms). The Java client remains alive for a 30-second grace period by
default (`TRADING_SOAK_HOLD_OPEN_MS`) so the faster client cannot tear down
the cluster while Zig is still draining its orders. Java order IDs start at
`1`, while Zig IDs start at `1_000_001`, so the two clients can run
concurrently without collisions.

The two projects can also be controlled directly:

```bash
COMPOSE="${COMPOSE:-compose}"
$COMPOSE -p aeron-java-cluster -f deploy/trading/docker-compose.java-cluster.yml up -d --build
$COMPOSE -p aeron-java-clients -f deploy/trading/docker-compose.java.yml up --build
$COMPOSE -p aeron-java-clients -f deploy/trading/docker-compose.java.yml down --remove-orphans
$COMPOSE -p aeron-java-cluster -f deploy/trading/docker-compose.java-cluster.yml down --remove-orphans
```

For parallel or repeatable runs, set `TRADING_PROJECT_SUFFIX` to give both
Compose projects a unique name while retaining the same shared network contract:

```bash
TRADING_PROJECT_SUFFIX=task2b TRADING_SOAK_MESSAGES=100000 \
  uv run scripts/trading.py soak --mode java
```

Java images use the locally cached authentic Aeron artifact from the vendored
`vendor/aeron` source. `test/interop/aeron-all.jar` is the stable local cache;
the first preparation builds from the submodule only when that file is absent.
Later Compose builds copy that exact file and do not download or rebuild it.
To prepare it explicitly, run `uv run scripts/trading.py ensure-java-artifact`.

The 500-order soak is currently green. A 100,000-order run exercises the
Java-cluster path well past the previous burst-loss boundary:

```bash
TRADING_SOAK_MESSAGES=100000 uv run scripts/trading.py soak --mode java
```

The publisher rotates terms with stream-identifying padding and the sender
follows rotated partitions. The Java-cluster 100,000-order gate is green for
both implementations. On a fresh three-member cluster with a 5-second startup
delay, Java completed `100000` responses in `438 ms` (`228310/s`) and Zig
completed `100000` responses in `1726 ms` (`57937/s`). The embedded driver now
uses a 4 MiB UDP receive buffer and queues incoming NAKs for sender
retransmission; sustained multi-hour soak evidence is still part of the
unreleased 0.9 hardening work.

The checked-in concurrent runner was also green at 100k: Java completed in
`910 ms` (`109890/s`) while Zig completed in `2080 ms` (`48076/s`), with both
clients reporting exactly 100,000 responses and the command exiting zero.

The canonical mixed topology also passed a bounded 100,000-order run on
2026-07-19. Java completed in `906 ms` (`110375/s`) and Zig completed in
`1754 ms` (`57012/s`); both clients reported exactly 100,000 responses. The
mixed Compose client files now interpolate `ORDER_COUNT` and timeout settings
from the runner, so this is a real 100k run rather than the default three-order
smoke. The Zig member observes and journals the Java service log in this
topology, but orders are still handled by the Java leader. This is mixed
consensus/client and log-ingress evidence, not full Zig service/log parity.

The lower-level Java↔Zig media-driver interop soak also passed with 1,000
messages on 2026-07-19, including counters, multi-stream, exclusive-publication,
and reconnect checks. Run it independently with:

```bash
COMPOSE=podman-compose INTEROP_SOAK_MESSAGES=1000 make interop-soak-0.9
```

Both clients report `publish_ms`, `total_ms`, and `orders_per_sec`. Compare
those values only between runs with the same order count and topology.

Current performance evidence on the local host:

| scenario | orders | publish | total | throughput | result |
| --- | ---: | ---: | ---: | ---: | --- |
| Java cluster + Java client | 10,000 | 44 ms | 167 ms | 59,880/s | pass |
| Java cluster + Java client | 100,000 | 69 ms | 438 ms | 228,310/s | pass |
| Java cluster + Zig client | 10,000 | 208 ms | 225 ms | 44,444/s | pass |
| Java cluster + Zig client | 100,000 | 1,724 ms | 1,726 ms | 57,937/s | pass |
| Mixed cluster + Java client | 100,000 | 195 ms | 906 ms | 110,375/s | pass |
| Mixed cluster + Zig client | 100,000 | 1,753 ms | 1,754 ms | 57,012/s | pass |

These are bounded parity gates, not long-duration soak evidence. Run them with
one active cluster alias set, wait for election readiness, and retain the
explicit hard timeouts. Reusing a cluster during rapid client restarts can
produce a connect timeout before the service accepts a new ClusterSession; that
run is invalid evidence and should be repeated on a fresh project.

Enable low-noise client tracing with `TRACE_PERF=1` in the Zig container. The
10,000-order trace reported bounded `doWork`, offer, and egress polling costs;
the remaining performance gap at 100k is now a measurable optimization task,
not a response-completeness failure.

For larger runs, the soak runner gives the Zig client a 10-minute batch offer
deadline and 10 million connect iterations by default. Override
`TRADING_SOAK_OFFER_TIMEOUT_MS`, `TRADING_SOAK_RESPONSE_TIMEOUT_MS`, or
`TRADING_SOAK_CONNECT_MAX_ITERATIONS` when testing a slower host. The outer
Compose operation has a 15-minute hard deadline by default; override
`TRADING_SOAK_HARD_TIMEOUT_MS` for a longer soak. If that deadline expires,
the runner returns exit code 124 and removes both the client and cluster
projects.

Matching rules are deterministic:

1. A bid crosses the lowest resting ask at or below its limit price.
2. An ask crosses the highest resting bid at or above its limit price.
3. Equal-price orders are matched in arrival order.
4. A residual quantity rests on the book.
5. Invalid orders and duplicate order IDs are rejected.

The language-local tests cover the same three classes in both implementations:
happy matching, evil invalid/duplicate input, and edge resting orders. They
also assert equal-price FIFO so the Zig book cannot silently diverge from the
Java queue implementation.
