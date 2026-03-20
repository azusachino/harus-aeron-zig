# Setup

## Prerequisites

- Nix with flakes enabled (`nix develop`)
- colima (for local Kubernetes via k3s)
- macOS or Linux

## Getting Started

```bash
# Enter dev shell (provides zig 0.15.2, zls, prettier, skopeo)
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

## Zig Version

Zig 0.15.2 is provided via `nixpkgs.legacyPackages.${system}.zig` in `flake.nix`.
No `zig-overlay` or mise needed — just `nix develop`.

---

## Local Kubernetes (k3s via Colima)

### Stack

| Layer | Tool | Notes |
|-------|------|-------|
| VM | [colima](https://github.com/abiosoft/colima) 0.10+ | Lightweight VM for macOS |
| Runtime | **containerd** | Must use containerd, NOT docker (see below) |
| Orchestration | k3s (v1.35+) | Ships with colima |
| OCI images | Nix `dockerTools.buildImage` | No Docker daemon needed for builds |
| Image transport | `nerdctl load` | Push OCI tarballs into containerd |

### Critical: Use containerd, NOT docker

Colima's `--runtime docker --kubernetes` is **broken with modern k3s** (v1.24+).
k3s dropped native `--docker` support; the `cri-dockerd` shim is unstable.

Symptoms:
- k3s service crashes in a loop
- `kubectl get nodes` → "connection refused"
- Logs show: `lstat /var/lib/docker/image: no such file or directory`

**Fix**: always use `--runtime containerd`:

```bash
colima start --runtime containerd --kubernetes --cpu 4 --memory 4 --disk 20
```

References:
- [abiosoft/colima#957](https://github.com/abiosoft/colima/issues/957) — docker+k3s broken
- [abiosoft/colima#759](https://github.com/abiosoft/colima/issues/759) — k3s won't start with Docker runtime
- [abiosoft/colima#1373](https://github.com/abiosoft/colima/issues/1373) — k3s starts before IP assignment

### Quick Start

```bash
# 1. Start colima with containerd + k3s
make colima-up

# 2. Build OCI image via Nix (no Docker daemon, ~320KB image)
nix build .#oci

# 3. Load image into containerd (NOT docker load)
colima nerdctl load < result

# 4. Deploy to k3s
make k8s-up

# 5. Check status
make k8s-status

# 6. View cluster node logs
make k8s-logs

# 7. Tear down
make k8s-down
make colima-down
```

### Building OCI Images with Nix

We use `pkgs.dockerTools.buildImage` from nixpkgs instead of Dockerfile:

```bash
nix build .#oci        # produces result → .tar.gz (~320KB)
```

Benefits:
- **No Docker daemon** needed for building
- **Reproducible** — same inputs always produce same image
- **Minimal** — only the Zig binary, no base OS layer
- **Fast** — Nix caching means rebuilds only recompile changed code

### Loading Images into containerd

With containerd runtime, images must be loaded into the **`k8s.io` namespace** —
this is where k3s/kubelet looks for images. `nerdctl load` puts images in the
`default` namespace which k8s can't see.

```bash
# Load into both namespaces (make nix-image does this automatically)
colima nerdctl load < result
colima ssh -- sudo ctr -n k8s.io images import - < result

# Verify in k8s namespace
colima ssh -- sudo ctr -n k8s.io images ls | grep harus
```

k8s manifests must use `imagePullPolicy: Never` for local images.

### Youki (Rust OCI Runtime) — Optional

[youki](https://github.com/youki-dev/youki) is a Rust-based OCI container runtime
(runc replacement). Available in nixpkgs (`pkgs.youki`, v0.6.0).

Benefits over runc: faster startup, lower memory, memory safety (Rust vs C).

To use in k3s, create a `RuntimeClass` and set `runtimeClassName: youki` on pods.
See [youki docs](https://youki-dev.github.io/youki/) for configuration.

---

## Troubleshooting

### "connection refused" from kubectl

1. Check colima: `colima status`
2. Check k3s health: `colima ssh -- sudo systemctl status k3s`
3. Wait 30–60s after start — k3s needs time to initialize
4. Check logs: `colima ssh -- sudo journalctl -u k3s -n 50`

### k3s keeps crashing

- Ensure `--runtime containerd` (NOT docker)
- Delete and recreate: `colima delete --force && make colima-up`
- Check memory: 4GB minimum recommended

### Image not found in k8s

- Use `colima nerdctl load` (not `docker load`) with containerd runtime
- Verify: `colima nerdctl images`
- Ensure `imagePullPolicy: Never` in manifests

### Cross-compilation (macOS → Linux)

Zig handles this natively:
```bash
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux
```
The Nix flake does this automatically via `nix build .#oci`.

---

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
