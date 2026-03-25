# Architecture — harus-aeron-zig

Reference implementation: https://github.com/aeron-io/aeron

## Overview

Aeron is a high-performance messaging system using UDP transport. It provides:

- **Reliable** unicast and multicast delivery over UDP via NAK-based retransmission
- **Zero-copy** data path via memory-mapped log buffers shared between driver and clients
- **Back-pressure** via flow control (receiver window, sender position)
- **Low-latency** through busy-spin duty cycles (no OS blocking in the hot path)

## Component Map

```
┌─────────────────────────────────────────────────────────────────┐
│                         Client Process                          │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────────┐  │
│  │ Publication │  │ Subscription │  │   Aeron (context)     │  │
│  └──────┬──────┘  └──────┬───────┘  └───────────────────────┘  │
│         │ write          │ read                                  │
│  ┌──────▼──────────────▼─────┐  ┌────────────────────────────┐  │
│  │     Log Buffers (mmap)    │  │  Ring Buffer (client→drv)  │  │
│  │  [term0][term1][term2]    │  │  BroadcastRx (drv→client)  │  │
│  └───────────────────────────┘  └────────────────────────────┘  │
└─────────────────────────┬────────────────────┬──────────────────┘
                          │ mmap shared memory  │ mmap IPC
┌─────────────────────────▼────────────────────▼──────────────────┐
│                        Media Driver Process                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                      Conductor                           │   │
│  │  (command/control: add pub, add sub, manage resources)   │   │
│  └────────────┬───────────────────────────┬─────────────────┘   │
│               │                           │                      │
│  ┌────────────▼──────────┐   ┌────────────▼────────────────┐    │
│  │        Sender         │   │         Receiver            │    │
│  │  - reads log buffer   │   │  - writes log buffer        │    │
│  │  - sends DATA frames  │   │  - sends STATUS/NAK frames  │    │
│  │  - sends SETUP frames │   │  - handles SETUP frames     │    │
│  └────────────┬──────────┘   └────────────┬────────────────┘    │
└───────────────┼─────────────────────────── ┼────────────────────┘
                │  UDP unicast/multicast      │
          ┌─────▼─────────────────────────────▼────┐
          │          Network / UDP Socket           │
          └─────────────────────────────────────────┘
```

## Module Breakdown

### `src/protocol/`

Wire frame codecs. All types are `extern struct` with exact byte layout.

| File | Contents |
|------|----------|
| `frame.zig` | DataHeader, SetupHeader, StatusMessage, NakHeader, RttMeasurement |

### `src/logbuffer/`

Three-partition term buffer backed by memory-mapped files. Publishers write to the active term;
the driver reads from it to send DATA frames. Receivers write incoming DATA into subscriber log buffers.

| File | Contents |
|------|----------|
| `log_buffer.zig` | LogBuffer struct, partition constants |
| `term_appender.zig` | TermAppender — atomic tail advance, frame write |
| `term_reader.zig` | TermReader — read forward from offset |
| `metadata.zig` | LogBufferMetadata — active term, tail counters |

### `src/ipc/`

Shared memory IPC between client and driver.

| File | Contents |
|------|----------|
| `ring_buffer.zig` | ManyToOneRingBuffer — client→driver commands (add pub/sub, heartbeat) |
| `broadcast.zig` | BroadcastTransmitter/Receiver — driver→client notifications |
| `counters.zig` | CountersMap — shared position counters (publisher limit, subscriber position) |

### `src/transport/`

UDP network layer and URI parsing.

| File | Contents |
|------|----------|
| `uri.zig` | AeronUri — parses `aeron:udp?...` into params |
| `udp_channel.zig` | UdpChannel — resolves hostnames, multicast detection |
| `endpoint.zig` | SendChannelEndpoint, ReceiveChannelEndpoint |
| `poller.zig` | I/O multiplexing with `std.posix.poll` |

### `src/driver/`

Media driver agents and the CnC rendezvous.

| File | Contents |
|------|----------|
| `conductor.zig` | DriverConductor — commands, resource lifecycle |
| `sender.zig` | Sender — reads log buffer, sends DATA/SETUP |
| `receiver.zig` | Receiver — UDP frames, NAKs, writes log buffer |
| `cnc.zig` | CncFile — mmap layout and header creation |
| `media_driver.zig` | MediaDriver facade and agent orchestration |

### `src/archive/`

Persistent recording and replay.

| File | Contents |
|------|----------|
| `protocol.zig` | Control protocol message codecs |
| `catalog.zig` | Persistent recording directory |
| `conductor.zig` | ArchiveConductor — manage recording sessions |
| `recorder.zig` | Recording — write Aeron streams to disk |
| `replayer.zig` | Replayer — read from recording and send via Aeron |

### `src/cluster/`

Raft-based consensus.

| File | Contents |
|------|----------|
| `protocol.zig` | Client, Consensus (Raft), and Service message codecs |
| `election.zig` | Election state machine (init, canvass, candidate, leader) |
| `log.zig` | LogLeader and LogFollower replication progress |
| `cluster.zig` | ConsensusModule — top-level Raft agent |

### `src/`

Client library and top-level entry.

| File | Contents |
|------|----------|
| `aeron.zig` | Aeron client context and connection bootstrap |
| `publication.zig` | ExclusivePublication — atomic offer path |
| `subscription.zig` | Subscription — polls for and processes image frames |
| `cnc.zig` | CnC reader for clients |
| `main.zig` | Standalone MediaDriver binary |

## Aeron UDP Protocol

All frames share a base 8-byte header, then extend it:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Frame Length                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|    Version    |     Flags     |             Type              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

Frame types: DATA(0x01), SETUP(0x03), STATUS(0x04), NAK(0x05), RTT(0x0B)

### Data Flow (Publisher → Subscriber)

1. Publisher writes DATA frame into log buffer term (atomic tail advance)
2. Sender duty cycle reads from log buffer, sends UDP DATA frames
3. Receiver gets UDP DATA frame, validates session/stream, writes to subscriber log buffer
4. If gap detected → Receiver sends NAK, Sender retransmits
5. Subscriber polls log buffer term, invokes fragment handler

### Session Establishment (SETUP Handshake)

1. Sender sends SETUP frame (contains term_length, initial_term_id, mtu, ttl)
2. Receiver validates SETUP, creates Image, sends STATUS with receiver window
3. Data flow begins; flow control via STATUS window updates

## Phase History

- **v0.1.0 (2026-03-25)**: Media Driver, Archive, and Cluster implemented. Tutorial course complete (31 chapters). Upstream parity ongoing — not yet production-ready.
- **v0.5.0**: Initial preview. Basic IPC pub/sub working.

