# Setup

## Prerequisites

- Nix with flakes enabled (`nix develop`)
- colima + docker client (for integration testing against real Aeron Java driver)
- macOS or Linux

## Getting Started

```bash
# Enter dev shell (provides zig 0.15.2, zls, prettier)
nix develop

# Build
make build

# Run tests
make test

# Format
make fmt

# Full check (fmt + build + test)
make check
```

## Running the Media Driver

```bash
make run
# or directly:
zig-out/bin/aeron-driver
```

## Integration Testing Against Real Aeron

Pull the official Aeron Docker image to test wire compatibility:

```bash
# Start real Java Aeron media driver
docker run --rm -it \
  -v /dev/shm:/dev/shm \
  --network host \
  ghcr.io/real-logic/aeron:latest \
  java -jar aeron-samples/build/libs/aeron-samples.jar io.aeron.driver.MediaDriver

# Then run our integration tests
make test-integration
```

## Zig Version

Zig 0.15.2 is provided via `nixpkgs.legacyPackages.${system}.zig` in `flake.nix`.
No `zig-overlay` or mise needed — just `nix develop`.
