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

UDP network layer.

| File | Contents |
|------|----------|
| `udp_channel.zig` | UdpChannel — socket, bind, multicast join/leave, send/recv |
| `endpoint.zig` | SendChannelEndpoint, ReceiveChannelEndpoint — manage channels per URI |
| `poller.zig` | I/O polling loop (poll/select), dispatch to endpoints |

### `src/driver/`

Media driver agents — each runs a duty-cycle loop.

| File | Contents |
|------|----------|
| `conductor.zig` | DriverConductor — processes client commands, manages pub/sub lifecycle |
| `sender.zig` | Sender — reads publications, sends DATA + SETUP, manages retransmit |
| `receiver.zig` | Receiver — dispatches incoming frames, writes to subscriber log buffers |
| `media_driver.zig` | MediaDriver — launches agents, owns all resources |

### `src/`

| File | Contents |
|------|----------|
| `aeron.zig` | Aeron client context — connect to driver, create pub/sub |
| `publication.zig` | ExclusivePublication, ConcurrentPublication |
| `subscription.zig` | Subscription — poll for new images, invoke fragment handlers |
| `image.zig` | Image — one received stream from one publisher |
| `main.zig` | Driver binary entry — parse args, start MediaDriver |

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

## Phase Roadmap

1. **Phase 1 — Media Driver**: full pub/sub over UDP, wire-compatible
2. **Phase 2 — Archive**: record and replay via `aeron-archive`
3. **Phase 3 — Cluster**: Raft consensus via `aeron-cluster`

See `docs/plan.md` for detailed task breakdown.
