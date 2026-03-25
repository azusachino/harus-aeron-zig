NIX_RUN := $(if $(IN_NIX_SHELL),,nix develop --command )
export ZIG_GLOBAL_CACHE_DIR := $(CURDIR)/.zig-global-cache
export ZIG_LOCAL_CACHE_DIR := $(CURDIR)/.zig-cache
AERON_VERSION := 1.46.7
AERON_ALL_JAR_URL := https://repo1.maven.org/maven2/io/aeron/aeron-all/$(AERON_VERSION)/aeron-all-$(AERON_VERSION).jar
AERON_ALL_JAR_SHA256 := ded2ed3c5b73991e31c439a7562a294e5d5566f955c3a9e81089a28a6b5b9d55

.PHONY: fmt fmt-check build test lint check clean run tutorial-check lesson-lint \
       fuzz bench stress \
       nix-image k8s-up k8s-down k8s-status k8s-logs colima-up colima-down \
       setup setup-interop \
       interop interop-smoke interop-status test-protocol test-driver test-archive test-cluster test-scenarios status

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

test-protocol:  ## Run protocol scenario tests
	$(NIX_RUN) zig build test-protocol

test-driver:  ## Run driver scenario tests
	$(NIX_RUN) zig build test-driver

test-archive:  ## Run archive scenario tests
	$(NIX_RUN) zig build test-archive

test-cluster:  ## Run cluster scenario tests
	$(NIX_RUN) zig build test-cluster

test-scenarios: test-protocol test-driver test-archive test-cluster  ## Run all scenario tests

lint: fmt-check

lesson-lint:  ## Verify all LESSON annotation slugs have a matching docs/tutorial/ chapter file
	bash scripts/lesson-lint.sh

check: fmt-check build test test-scenarios lesson-lint  ## Full check: fmt + build + all tests

status:  ## Show parity and chapter status from JSONL sources
	@echo "=== Parity Gaps ==="
	@jq -r '"\(.layer): \(.completeness_pct)% — gaps: \(.gaps | join(", "))"' .agents/parity_status.jsonl
	@echo ""
	@echo "=== Upstream Map — pending ==="
	@jq -r 'select(.status == "pending") | "\(.layer)/\(.upstream_class)"' test/upstream_map.jsonl
	@echo ""
	@echo "=== Chapter Status — incomplete ==="
	@jq -r 'select(.status != "done") | "\(.id) \(.slug): \(.status)"' .agents/chapter_status.jsonl

run:
	$(NIX_RUN) zig build run

tutorial-check:
	$(NIX_RUN) zig build tutorial-check

clean:
	rm -rf zig-out .zig-cache .zig-global-cache

setup: setup-interop  ## Prepare local helper artifacts for interop and benchmarks

setup-interop:
	@mkdir -p vendor
	@std_dir="$$( $(NIX_RUN) zig env | sed -n 's/.*"std_dir": *"\([^"]*\)".*/\1/p' )"; \
	if [ -n "$$std_dir" ]; then \
		ln -sfn "$$std_dir" vendor/zig-std; \
	fi
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
	kubectl apply -k k8s/

k8s-down:
	kubectl delete -k k8s/ --ignore-not-found

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

interop:  ## Run full interop test suite (100 messages, all scenarios)
	docker compose -f deploy/docker-compose.ci.yml up --abort-on-container-exit

interop-smoke:  ## Run quick smoke interop test (10 messages, CI-friendly)
	docker compose -f deploy/docker-compose.ci.yml up --abort-on-container-exit

interop-status:  ## Show status of running interop jobs
	@echo "=== Interop Jobs ==="
	kubectl get jobs -n aeron -l 'app.kubernetes.io/part-of in (interop,interop-smoke)' -o wide 2>/dev/null || \
		echo "(no interop jobs found — run 'make interop' or 'make interop-smoke')"
	@echo ""
	@echo "=== Interop Pods ==="
	kubectl get pods -n aeron -l 'app.kubernetes.io/part-of in (interop,interop-smoke)' -o wide 2>/dev/null || true

