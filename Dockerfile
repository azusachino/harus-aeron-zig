# Multi-stage build for Aeron Zig binaries
# Stage 1: Build with Zig
FROM alpine:3.21 AS builder

RUN apk add --no-cache curl xz

# Install Zig 0.15.2
ARG ZIG_VERSION=0.15.2
ARG TARGETARCH
RUN ARCH=$(uname -m) && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt && \
    ln -s /opt/zig-${ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig && \
    ln -s /opt/zig-${ARCH}-linux-${ZIG_VERSION}/lib /usr/local/lib/zig

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY test/ test/
COPY examples/ examples/
COPY tutorial/ tutorial/

# Build release binaries
RUN zig build -Doptimize=ReleaseSafe

# Stage 2: Minimal runtime
FROM alpine:3.21

RUN apk add --no-cache tini

COPY --from=builder /src/zig-out/bin/ /usr/local/bin/

# Shared memory directory for Aeron IPC
RUN mkdir -p /dev/shm/aeron

ENTRYPOINT ["tini", "--"]
CMD ["aeron-driver"]
