FROM nixos/nix:latest AS builder
WORKDIR /src
COPY . .
RUN nix --extra-experimental-features nix-command --extra-experimental-features flakes develop --command make build

FROM nixos/nix:latest
WORKDIR /app
COPY --from=builder /src/zig-out/bin/aeron-driver /app/aeron-driver
RUN mkdir -p /dev/shm/aeron && ln -sf /dev/shm/aeron /dev/shm/aeron-root
EXPOSE 20121/udp
CMD ["/app/aeron-driver"]
