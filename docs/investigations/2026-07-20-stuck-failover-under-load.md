# Pure-Zig Cluster Failover Gets Stuck Under Sustained Load

While proving pure-Zig leader failover end-to-end (`harus-aeron-zig:zig-cluster-parity` task-5),
light-load failover was verified clean and correct repeatedly: kill the leader within a
few seconds of cluster boot (well under 100 internal-stream messages) and the survivors
elect a new leader via a real RequestVote/Vote quorum, then keep processing client
orders normally.

Under sustained load, failover instead gets **stuck forever**. The symptom:

```text
ZIG_CLUSTER_LEADER_CHANGE member=1 leader=0 term=1 source=new_leadership_term
ZIG_CLUSTER_LEADER_CHANGE member=1 leader=0 term=1 source=new_leadership_term
ZIG_CLUSTER_LEADER_CHANGE member=1 leader=0 term=1 source=new_leadership_term
... (repeats indefinitely, member 0 is dead)
```

The correlating variable is total elapsed time/message volume on the internal cluster
stream, not specifically client order throughput — it reproduces both after ~100+
client orders and after ~90-130+ seconds of pure idle heartbeat/ack traffic with no
client orders at all. Once triggered, followers never time out the dead leader and
never re-elect.

## Reproduction (host, no containers)

```bash
nix develop --command zig build examples   # produces zig-out/bin/zig-cluster-node, zig-cluster-client

for i in 0 1 2; do
  CLUSTER_MEMBER_ID=$i CLUSTER_LEADER_MEMBER_ID=0 ELECTION_TIMEOUT_MS=5000 \
  INGRESS_PORT=$((19010+i)) INTERNAL_PORT=$((19010+i)) \
  AERON_DIR=/tmp/aeron-hosttest-node-$i CLUSTER_ARCHIVE_DIR=/tmp/archive-hosttest-node-$i \
  CLUSTER_ENDPOINTS="0=127.0.0.1:19010,1=127.0.0.1:19011,2=127.0.0.1:19012" \
  CLUSTER_INTERNAL_ENDPOINTS="0=127.0.0.1:19010,1=127.0.0.1:19011,2=127.0.0.1:19012" \
  ./zig-out/bin/zig-cluster-node > /tmp/hosttest-node-$i.log 2>&1 &
done

# Give election a few seconds, then generate load:
AERON_DIR=/tmp/aeron-hosttest-client \
INGRESS_ENDPOINTS="127.0.0.1:19010,127.0.0.1:19011,127.0.0.1:19012" \
RESPONSE_CHANNEL="aeron:udp?endpoint=127.0.0.1:0" \
ORDER_COUNT=3000 START_DELAY_MS=0 OFFER_TIMEOUT_MS=60000 RESPONSE_TIMEOUT_MS=60000 \
./zig-out/bin/zig-cluster-client > /tmp/hosttest-client.log 2>&1 &

# Once the client is mid-stream (check /tmp/hosttest-client.log), kill the leader:
kill -9 <node0 pid>

# Watch a follower's log keep repeating ZIG_CLUSTER_LEADER_CHANGE forever:
grep -c ZIG_CLUSTER_LEADER_CHANGE /tmp/hosttest-node-1.log   # keeps growing
```

`RESPONSE_CHANNEL` must be overridden to `aeron:udp?endpoint=127.0.0.1:0` for a host
run — the default (`zig-client:0`) is a docker-compose service name and only
resolves inside that network.

## What was ruled out

1. **Not a regression from tasks 2-4** (log replication, Archive-backed durable
   storage, ClusteredService lifecycle callbacks — all added in this same work
   session). Checked out commit `165f29c` (right after task-1, before any of that
   work) into a throwaway `git worktree`, ran the identical repro there, and it
   reproduced identically. This bug predates all of that code.
2. **Not a Podman/macOS-VM container-networking artifact.** The host repro above
   (plain processes, no containers, no podman-machine) reproduces the same
   stuck-forever symptom.
3. **Not driven by the trading sample's own retransmission logic**
   (`examples/trading/zig_cluster_node.zig`, added in task-2). Confirmed via the
   task-1-baseline worktree test in (1) — the bug predates that code entirely.
4. **Not NAK/retransmission-driven** at the Aeron driver level
   (`src/driver/receiver.zig`, `src/driver/sender.zig`). Temporary debug prints at
   the inbound-NAK-frame handling site and the `sendRetransmit()` call site (both
   gated on `stream_id == 103`, the internal cluster stream) showed **zero** NAK
   frames received and **zero** retransmits sent for the entire duration of a
   reproduced stuck window.

## Decisive finding: the kernel syscall itself reports a phantom read

Captured the actual wire traffic during a host repro with:

```bash
sudo tcpdump -i lo0 -n udp port 19010 -w /tmp/repro.pcap
```

Node 0's last real packet went out at Unix time `1784511465.758073` — 0.7ms before
the `kill -9` (`1784511465.758817`) — and **zero** packets to or from that port
appear anywhere later in the 30,176-packet capture.

Meanwhile, in a separately-instrumented run (debug prints added directly at the
inbound-frame decode site in `receiver.zig`, gated on `stream_id == 103`), the
surviving node kept logging "received" internal-stream frames carrying node0's
exact session id and source port, repeating the *same* `term_offset` sequence,
for 20+ seconds after the kill.

A print was then added directly at the `recvfrom()` return value in `src/net.zig`
— before any of this repo's own error/success interpretation:

```zig
const rc = std.posix.system.recvfrom(fd, buf.ptr, buf.len, flags, src, addrlen);
// rc kept coming back positive (e.g. rc=128, a genuine byte count) over and
// over on the one shared UDP socket, with no corresponding wire packet.
```

This rules out every remaining application-layer explanation (this repo's
error-code handling, buffer slicing, image/session demuxing) — the raw syscall
itself is reporting a phantom successful read. That points to a macOS/XNU
kernel-level UDP socket receive-queue bug (a stuck/undequeued entry being
redelivered under sustained load on a nonblocking socket) rather than a defect
in this repo's own driver code, as best as can be determined without
OS-level tracing (`dtruss`/Instruments) or a same-repro comparison on Linux.

All debug instrumentation added during this investigation was reverted
(commit `955b7d6`) — do not re-add without gating behind a build flag.

## Next steps

- Re-run the exact host repro above on Linux. If it does **not** reproduce there,
  that confirms the macOS/XNU kernel hypothesis and this becomes a documented
  macOS-only dev-environment limitation rather than a shipped defect — task-5 can
  close.
- If it **does** reproduce on Linux too, the kernel hypothesis is wrong and the bug
  is genuinely in this repo's own socket/receiver code (`src/net.zig::recvFrom`,
  `src/driver/receiver.zig::doWork`/`processDatagram`,
  `src/transport/endpoint.zig`). Re-add the debug prints removed in `955b7d6` as a
  starting point, and use `strace` (the Linux equivalent of the `dtruss`/`tcpdump`
  work already done here) to see the raw syscall sequence.
