# What Is Aeron?

Aeron is a high-performance messaging library designed for environments where microseconds
matter: electronic trading, real-time telemetry, game servers, and anything else that cannot
afford the latency introduced by general-purpose messaging systems.

## The Problem: Why TCP Falls Short

TCP is a reliable, ordered byte stream. Those properties sound desirable until you run into
what they cost:

- **Head-of-line blocking.** A single dropped packet stalls all data behind it until
  retransmission completes. For a stream carrying 500,000 messages per second, one drop
  can cost tens of milliseconds.
- **Kernel involvement on every send/receive.** Each `send()` and `recv()` is a syscall.
  At high message rates the syscall overhead alone saturates a core.
- **Nagle's algorithm and delayed ACK.** Unless carefully disabled, TCP batches small
  writes and delays ACKs — adding 40–200 ms of artificial latency.
- **Backlog growth.** When a slow consumer can't keep up, the kernel's TCP send buffer
  grows, introducing variable queue latency ("buffer bloat").

Aeron's thesis: **at high message rates, you can build more reliable, lower-latency
delivery on top of UDP if you own the retry and flow-control logic yourself.**

## Aeron's Solution

Aeron uses **UDP** for network transport and **memory-mapped files** for same-host IPC.
The core data structure is the **log buffer**: a contiguous region of shared memory divided
into three equal partitions (terms). Publishers write frames into the active term using an
atomic tail pointer. The Media Driver reads those frames and sends them over UDP. On the
receiving side, incoming UDP frames land in the subscriber's log buffer. The subscriber
polls those frames directly — no copying from kernel space, no extra locks.

Key design decisions:

- **Zero-copy end to end.** The publisher writes once into the log buffer. The driver reads
  from that same memory to send, and the subscriber reads received frames from its own
  log buffer. No intermediate heap allocation, no `memcpy` on the hot path.
- **Back-pressure, not blocking.** When the log buffer is full, `offer()` returns a
  sentinel (`BACK_PRESSURED` or `ADMIN_ACTION`) rather than blocking the caller. The
  application decides how to handle it — spin, yield, or drop.
- **Selective flow control.** The driver tracks each subscriber's consumption position via
  a shared counter. The sender will not advance beyond the slowest subscriber's window.
  This prevents a fast publisher from outrunning a slow subscriber indefinitely, while
  also not blocking the whole channel for one lagging consumer.

## Where Aeron Is Used

- **Electronic trading**: orders, market data, risk limits. Latencies in the
  low-microsecond range, millions of messages per second.
- **Telemetry and monitoring**: streaming sensor data from aircraft, racing cars, or
  industrial control systems.
- **Online gaming**: authoritative server state broadcast to thousands of clients with
  deterministic timing.
- **Financial data distribution**: LMAX Disruptor's network layer uses Aeron.

## The Three Process Roles

Every Aeron deployment involves at least two processes, and the work is split three ways:

```
Publisher Process               Media Driver Process          Subscriber Process
┌──────────────────┐            ┌──────────────────────┐      ┌─────────────────┐
│  Publication     │──mmap────▶ │  Conductor           │      │  Subscription   │
│  offer(msg)      │            │  Sender ──UDP──────────────▶│  poll(handler)  │
│                  │            │  Receiver ◀──UDP───────────  │                 │
└──────────────────┘            └──────────────────────┘      └─────────────────┘
```

- **Media Driver**: a long-running process that owns sockets, manages subscriptions, and
  runs the duty-cycle agents (Sender, Receiver, Conductor). Clients connect to it via IPC.
- **Publisher**: a client process that calls `offer()`. It writes frames into a log buffer
  that the driver reads from.
- **Subscriber**: a client process that calls `poll()`. It reads frames from a log buffer
  that the driver wrote into.

The publisher and subscriber never talk directly to each other. The driver mediates.

## How Aeron Compares

| | Aeron | Kafka | ZeroMQ | NATS |
|---|---|---|---|---|
| Persistence | No (log is in memory) | Yes (disk) | No | Optional (JetStream) |
| Latency | Sub-microsecond (IPC) / ~10 µs (UDP) | Milliseconds | ~10 µs | ~100 µs |
| Flow control | Per-subscriber position counters | Consumer group offsets | High-water mark | Token bucket |
| Broker required | Media Driver (same host or remote) | Yes | No | Yes (server) |
| Best for | Low-latency, high-throughput streams | Durable event logs | Flexible topology | Cloud microservices |

Choose Aeron when latency and throughput are the primary constraints and you can operate
the Media Driver. Choose Kafka when durability and replay matter more. Choose NATS when
you want a simple broker with decent performance but without the operational cost of tuning
a media driver.
