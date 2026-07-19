# Mixed Java/Zig cluster boundary

The mixed topology now has a real three-process probe: two authentic Java
`ClusteredMediaDriver` members and one Zig member speaking the Java SBE
consensus and log streams. It is a verified 0.9 interop slice, not yet full
cluster parity, because the Zig member still lacks Java-compatible service
application, catchup, archive, ingress ownership, and durable replay services.

## What the Java members actually speak

The vendored Aeron source defines the member protocol in
`vendor/aeron/aeron-cluster/src/main/resources/cluster/aeron-cluster-codecs.xml`:

- SBE schema id `111`, version `15`, little-endian;
- an 8-byte message header containing block length, template id, schema id,
  and version;
- consensus templates 50-57, including canvass, vote, new leadership term,
  append position, commit position, catchup, and stop catchup;
- separate log and catchup channels in addition to ingress, consensus, and
  archive endpoints.

`ConsensusAdapter` and `ConsensusPublisher` in the vendored Java source use
those generated SBE codecs on the consensus channel. The current Zig trading
sample instead uses a private 13-byte `ZCL1` heartbeat/order frame on a normal
Aeron stream. Its client-facing session/egress codec is compatible enough for
Java/Zig client interoperability, but its member protocol is not compatible
with `ClusteredMediaDriver`.

## Required implementation before full mixed acceptance

The Zig member needs a complete Cluster adapter that:

1. encodes and decodes the SBE header and templates 50-57 with exact block
   lengths and optional fields;
2. owns separate consensus, log, and catchup publications/subscriptions;
3. feeds those messages into the existing election/log/conductor state rather
   than only observing them;
4. applies the replicated service log and persists log/snapshot positions
   through restart; and
5. proves two Java members can elect, replicate, fail over, and replay with
   the Zig member present.

The Java topology remains the authentic baseline, and the pure-Zig topology
remains a useful process-boundary/sample failover test. This is now a
member-protocol and state-replication gap, not a container or shared-network
problem. The first implementation slice exists in
`src/cluster/aeron_consensus_codecs.zig` and
`src/cluster/aeron_consensus_adapter.zig`: exact SBE headers/templates are
validated and a Java-shaped RequestVote produces a Java-shaped Vote through
the existing election state machine. `examples/trading/zig_consensus_member.zig`
provides the network process boundary on consensus stream 108, and its
Containerfile is checked in. The election sentinel is aligned with Java's
`Aeron.NULL_VALUE` (`logLeadershipTermId=-1`), so Java RequestVote messages are
accepted and Java NewLeadershipTerm/CommitPosition messages are consumed. The
adapter now also preserves typed AppendPosition, CatchupPosition, and
StopCatchup notifications and advances follower progress from CommitPosition.

## Live probe evidence

The checked-in `docker-compose.consensus-probe.yml` proves a direct Java
generated-code exchange:

```text
ZIG_MIXED_MEMBER_RX member=2 template=51
ZIG_MIXED_MEMBER_TX member=2 count=1
JAVA_ZIG_CONSENSUS_INTEROP_OK template=52 vote=true
```

The expanded Java-generated probe sends the complete member-control subset:

```text
ZIG_MIXED_MEMBER_APPEND member=2 position=128 follower=2 flags=1
ZIG_MIXED_MEMBER_COMMIT member=2 position=128 leader=0
ZIG_MIXED_MEMBER_CATCHUP member=2 position=64 follower=2 endpoint=aeron:udp?endpoint=java-probe:9024
ZIG_MIXED_MEMBER_STOP_CATCHUP member=2 follower=2
JAVA_ZIG_CONSENSUS_INTEROP_OK templates=52,54,55,56,57 vote=true
```

This closes the SBE member-control decoding boundary. It does not mean that a
CatchupPosition starts Java-compatible log replay: the Zig member can receive
the normal log publication and sends an initial AppendPosition, but it still
lacks catchup-image lifecycle, Archive, snapshot, and clustered-service
lifecycle parity.

The larger `docker-compose.mixed-cluster.yml` starts two authentic Java
`ClusteredMediaDriver` members and the Zig process on the shared
`aeron-mixed` network. A fresh run produced this consensus trace:

```text
ZIG_MIXED_MEMBER_RX member=2 template=51 ... log_term=-1
ZIG_MIXED_MEMBER_RESPONSE member=2 request_template=51 response_len=44 state=follower_ballot
ZIG_MIXED_MEMBER_RX member=2 template=53 ...
ZIG_MIXED_MEMBER_RX member=2 template=55 ...
ZIG_MIXED_MEMBER_FOLLOWER member=2 leader=1 term=2
ZIG_MIXED_MEMBER_APPEND_TX member=2 position=0 follower=2
```

Both client implementations then submitted BTC_USDT orders through the Java
leader on the same mixed network:

```text
JAVA_CLUSTER_CLIENT_OK responses=3 publish_ms=3 total_ms=17 orders_per_sec=176
ZIG_CLUSTER_CLIENT_OK responses=3 publish_ms=0 total_ms=5 orders_per_sec=600
```

The same canonical topology passed a bounded 100,000-order run after the
client Compose files were fixed to propagate the runner's `ORDER_COUNT` and
timeout environment. The Java client completed in `906 ms` (`110375/s`) and
the Zig client completed in `1754 ms` (`57012/s`), with `100000/100000`
responses from each. This is mixed consensus/client soak evidence; the Zig
member observes and applies the Java log stream locally, but it is not the
active ingress service and must not be treated as a full pure-Zig cluster
benchmark.

This proves live Java↔Zig consensus-stream exchange, Java leader election with
the Zig member present, Java-compatible follower notifications, Java/Zig
client traffic through the elected Java cluster, and local application of
received log messages. It does not prove that Zig can become leader, accept
ingress directly, publish a Java-compatible log, serve catchup/archive
requests, persist snapshots, or lead recovery from a restarted log. Those
remain explicit 0.9 gaps; the canonical `mixed` runner is therefore a
consensus/client/log-observer smoke, not a full parity or benchmark gate.

## Live log-stream evidence

The mixed Zig member now subscribes to Java's default log stream 100 on the
shared `9022` endpoint. It accepts the Java SBE log header and journals each
frame, including control templates 21, 22, and 24 and application template 1.
A three-order run produced application traces such as:

```text
ZIG_MIXED_MEMBER_ORDER_RX member=2 count=3 session=1 payload=BTC_USDT|1|ASK|10100|10
ZIG_MIXED_MEMBER_ORDER_RX member=2 count=4 session=1 payload=BTC_USDT|2|BID|10050|4
ZIG_MIXED_MEMBER_ORDER_RX member=2 count=7 session=2 payload=BTC_USDT|1000001|ASK|10100|10
```

After restarting member 2, readiness reported `log_entries=11` and reconstructed
the order book from the journal. The checked-in runner reproduced the bounded
proof as `ZIG_MIXED_LOG_PROOF_OK member=2 log_entries=7 replayed_orders=2
minimum=2` with one order from each client. The journal and replay are local
durability seams only: they do not yet implement Java Cluster service replay,
catchup image publication, Archive recovery, snapshots, or leadership from the
recovered log.

A separate fast follower-rejoin experiment did not produce a Java
`CatchupPosition`: when the Zig member was absent, the two Java members entered
their election/recovery window and stopped accepting client sessions before a
valid replay could be observed. This is negative evidence, not a passing
catchup gate. The next acceptance test must preserve a live Java quorum while
forcing a follower whose append position is behind the leader, then require
templates 56/57 and replayed log frames on the Zig endpoint.
