NIX_RUN := $(if $(filter $(IN_NIX_SHELL),),nix develop --command ,)
export ZIG_GLOBAL_CACHE_DIR := $(CURDIR)/.zig-global-cache
export ZIG_LOCAL_CACHE_DIR := $(CURDIR)/.zig-cache

.PHONY: fmt fmt-check build test lint check clean run tutorial-check \
       fuzz bench stress \
       nix-image k8s-up k8s-down k8s-status k8s-logs colima-up colima-down \
       interop interop-build interop-run

fmt:
	$(NIX_RUN) zig fmt .
	$(NIX_RUN) prettier --write "**/*.{json,yaml,yml}"

fmt-check:
	$(NIX_RUN) zig fmt --check .
	$(NIX_RUN) prettier --check "**/*.{json,yaml,yml}"

build:
	$(NIX_RUN) zig build

build-driver:
	$(NIX_RUN) zig build driver

build-all:
	$(NIX_RUN) zig build -Dall

test:
	$(NIX_RUN) zig build test

test-unit:
	$(NIX_RUN) zig build test-unit

test-integration:
	$(NIX_RUN) zig build test-integration

lint: fmt-check

check: fmt-check build test

run:
	$(NIX_RUN) zig build run

tutorial-check:
	$(NIX_RUN) zig build tutorial-check

clean:
	rm -rf zig-out .zig-cache .zig-global-cache

# =============================================================================
# Kubernetes (k3s via colima)
# =============================================================================

IMAGE_NAME := harus-aeron-zig
IMAGE_TAG  := latest

colima-up:
	colima start --runtime containerd --kubernetes \
		--cpu 4 --memory 4 --disk 20

colima-down:
	colima stop

nix-image:
	nix build .#oci
	colima nerdctl load < result
	colima ssh -- sudo ctr -n k8s.io images import - < result

k8s-up: nix-image
	kubectl apply -k deploy/k8s/

k8s-down:
	kubectl delete -k deploy/k8s/ --ignore-not-found

k8s-status:
	@echo "=== Pods ==="
	kubectl -n aeron get pods -o wide
	@echo "\n=== Services ==="
	kubectl -n aeron get svc
	@echo "\n=== StatefulSet ==="
	kubectl -n aeron get statefulset

k8s-logs:
	@echo "=== Cluster Node 0 ===" && kubectl -n aeron logs aeron-cluster-0 --tail=20 2>/dev/null || true
	@echo "\n=== Cluster Node 1 ===" && kubectl -n aeron logs aeron-cluster-1 --tail=20 2>/dev/null || true
	@echo "\n=== Cluster Node 2 ===" && kubectl -n aeron logs aeron-cluster-2 --tail=20 2>/dev/null || true

# --- Performance & Hardening ---

fuzz:  ## Run fuzz tests
	$(NIX_RUN) zig build fuzz

bench:  ## Run benchmarks (ReleaseFast)
	$(NIX_RUN) zig build bench

stress:  ## Run stress tests
	$(NIX_RUN) zig build stress

# =============================================================================
# Interop Testing
# =============================================================================

interop: interop-build interop-run  ## Run full interop test suite

interop-build: nix-image  ## Build interop test images
	docker build -t java-aeron:latest -f deploy/interop/Dockerfile.java-aeron deploy/interop/
	nerdctl -n k8s.io image import $$(docker save java-aeron:latest | nerdctl -n k8s.io image load 2>&1 | grep -oP 'sha256:\S+') || \
		docker save java-aeron:latest | nerdctl -n k8s.io image load

interop-run:  ## Run interop test jobs in k3s
	kubectl delete jobs -n aeron -l app.kubernetes.io/part-of=interop --ignore-not-found
	kubectl apply -k deploy/interop/
	@echo "Waiting for interop jobs to complete..."
	kubectl wait --for=condition=complete --timeout=180s jobs -n aeron -l app.kubernetes.io/part-of=interop || \
		{ kubectl get jobs -n aeron -l app.kubernetes.io/part-of=interop -o wide >&2; \
		  echo "Interop jobs did not complete (timeout or failure)" >&2; exit 1; }
	@echo "All interop tests passed!"
