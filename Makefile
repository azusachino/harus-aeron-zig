NIX_RUN := $(if $(filter $(IN_NIX_SHELL),),nix develop --command ,)
export ZIG_GLOBAL_CACHE_DIR := $(CURDIR)/.zig-global-cache
export ZIG_LOCAL_CACHE_DIR := $(CURDIR)/.zig-cache
AERON_VERSION := 1.46.7
AERON_ALL_JAR_URL := https://repo1.maven.org/maven2/io/aeron/aeron-all/$(AERON_VERSION)/aeron-all-$(AERON_VERSION).jar

.PHONY: fmt fmt-check build test lint check clean run tutorial-check \
       fuzz bench stress \
       nix-image k8s-up k8s-down k8s-status k8s-logs colima-up colima-down \
       setup setup-interop \
       interop test-interop interop-build interop-run

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

test-interop:
	bash test/interop/run.sh

lint: fmt-check

check: fmt-check build test

run:
	$(NIX_RUN) zig build run

tutorial-check:
	$(NIX_RUN) zig build tutorial-check

clean:
	rm -rf zig-out .zig-cache .zig-global-cache

setup: setup-interop  ## Prepare local helper artifacts for interop and benchmarks

setup-interop:
	@mkdir -p test/interop vendor
	@std_dir="$$( $(NIX_RUN) zig env | sed -n 's/.*"std_dir": *"\([^"]*\)".*/\1/p' )"; \
	if [ -n "$$std_dir" ]; then \
		ln -sfn "$$std_dir" vendor/zig-std; \
	fi
	@curl -fsSL "$(AERON_ALL_JAR_URL)" -o test/interop/aeron-all.jar
	@if [ ! -s throughput ]; then \
		printf '%s\n' \
			'#!/usr/bin/env sh' \
			'set -e' \
			'zig build >/dev/null' \
			'exec zig-out/bin/throughput-example "$$@"' > throughput; \
			chmod +x throughput; \
		fi

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
	docker load < result
	docker save harus-aeron-zig:latest | colima ssh -- sudo ctr -n k8s.io images import -

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
# Consolidated into single `make interop` target that:
# - Builds OCI image (nix-image dependency)
# - Compiles Java Aeron interop apps
# - Deploys K8s jobs (java-pub-zig-sub, zig-pub-java-sub)
# - Waits for completion and reports results
# See: test/interop/k8s-verify.sh

interop:  ## Run full interop test suite
	bash test/interop/k8s-verify.sh

test-interop: interop  ## Backward-compatible alias for interop

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
