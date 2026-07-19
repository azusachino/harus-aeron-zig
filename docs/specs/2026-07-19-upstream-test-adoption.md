# Upstream Aeron test adoption

`vendor/aeron` is the compatibility authority for this project. Its tests are not copied
blindly: each adopted test must become either a Zig unit test, a byte-level conformance
fixture, or an external Java↔Zig runtime test with the same observable assertion.

## Current inventory

The vendored Aeron 1.50.x tree currently contains 142 Java test source files across the four
relevant modules. The repository also includes helper fixtures and support sources; the report
script counts only `src/test/**/*.java` files:

| Module | Upstream tests | Adoption target |
| --- | ---: | --- |
| `aeron-client` | 33 | codecs, log buffers, client lifecycle, publication/subscription semantics |
| `aeron-driver` | 41 | UDP setup/status, flow control, loss/retransmit, conductor lifecycle |
| `aeron-archive` | 30 | catalog, recording/replay, control protocol, recovery |
| `aeron-cluster` | 38 | SBE client protocol, ingress/egress, election, snapshot, restart/failover |

The existing `test/upstream_map.jsonl` records only selected translated tests. Its `done` entries
are evidence of local coverage, not proof that the entire upstream suite passes against Zig.

## Required first tranche

The following upstream tests define the current Java Cluster client boundary and must be adopted
before claiming Zig-client↔Java-cluster compatibility:

- `AeronClusterTest` — connect state machine, offer, keep-alive, close, redirect;
- `EgressPollerTest` — session event and new-leader event decoding;
- `SessionEventCodecCompatibilityTest` — exact SBE schema/header compatibility;
- `IngressAdapterTest` — session header stripping and application payload delivery.

The UDP prerequisite tranche is:

- `SenderTest` and `NetworkPublicationTest` — setup and data source port behavior;
- `ReceiverTest` and `FlowControlTest` — STATUS routing and publisher-limit advancement;
- `UdpChannelTest` and `SocketAddressParserTest` — hostname and ephemeral-port resolution.

The first UDP translation slice is now implemented in `test/driver/udp_conformance_test.zig`:
raw STATUS decoding, packed SETUP+STATUS dispatch, STATUS response wire layout and destination,
unicast/multicast flow-control limits, and ephemeral receive-port assignment. The mapping remains
`partial` because hostname matrices, setup retry cadence, and full NetworkPublication behavior
still need dedicated coverage.

## Adoption tiers

1. **Byte conformance** — fixed little-endian fixtures and SBE header/template assertions.
2. **Translated unit behavior** — Zig tests preserving upstream pre/postconditions.
3. **Cross-language runtime** — the official Java implementation drives or consumes the Zig path.
4. **Failure/soak** — leader loss, reconnect, replay, and long-running resource stability.

Only tiers 1–2 are currently green for the new Zig Cluster client. The Java-only three-member
baseline is green. The Zig-client-to-Java-cluster runtime test remains a required failing gate
until UDP setup/status and the Cluster session are observed end to end.

Generate the inventory with:

```bash
uv run scripts/upstream_tests.py report
```
