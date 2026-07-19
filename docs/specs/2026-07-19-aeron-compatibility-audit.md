# Aeron compatibility audit

This repository previously described the whole implementation as wire-compatible and reported
cluster parity without an external Java Cluster proof. That description was too broad.

## Verified boundary

The Zig `Aeron` API is a Media Driver client. It can be used for the ordinary Aeron publication
and subscription path when the corresponding driver and wire codecs agree.

The Zig `src/cluster/` code is currently an internal consensus model. Its client-facing structs
use custom message IDs and layouts; they are not the official Aeron Cluster SBE messages.
`examples/cluster_demo.zig` also drives three nodes in-process rather than launching three
networked cluster members.

## Required upstream Cluster surface

An interoperable Zig client must first implement the official client contract from
`vendor/aeron/aeron-cluster`:

- SBE message header and generated Cluster codecs;
- `SessionConnectRequest` with credentials, response channel, client info, and protocol version;
- the exact session message header and keep-alive encoding;
- egress `SessionEvent` and `NewLeaderEvent` decoding;
- leader redirect, endpoint update, reconnect, and session close behavior.

An interoperable Zig Cluster member additionally needs the upstream ingress, election,
replication, log, snapshot, archive, and service lifecycle contracts. Passing the existing
in-process Zig tests is not evidence for any of those Java boundaries.

## Acceptance rule

The compatibility claim will only be expanded after a real external test proves:

1. a Zig client opens a session with the Java three-member Cluster;
2. it submits and receives a `BTC_USDT` order response;
3. it survives leader loss and reconnects to the new leader; and
4. a Java client can perform the reciprocal flow against a Zig member.

Until then, Java Cluster and mixed Cluster modes remain blocked, while the Java-only sample is
the reference baseline.

The first external smoke also exposed two lower-level compatibility requirements now tracked in
code: container DNS names must resolve in UDP channel parsing, and the Media Driver must use a
shared UDP socket so Java `STATUS` replies return to the port that emitted `SETUP`. The client
also needs to advertise the resolved ephemeral egress port, matching Java's
`Subscription.tryResolveChannelEndpointPort()` behavior.
