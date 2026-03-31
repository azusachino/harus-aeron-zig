NIX_RUN := $(if $(IN_NIX_SHELL),,nix develop --command )
export ZIG_GLOBAL_CACHE_DIR := $(CURDIR)/.zig-global-cache
export ZIG_LOCAL_CACHE_DIR := $(CURDIR)/.zig-cache
AERON_VERSION := 1.50.2
AERON_ALL_JAR_URL := https://repo1.maven.org/maven2/io/aeron/aeron-all/$(AERON_VERSION)/aeron-all-$(AERON_VERSION).jar
AERON_UPSTREAM_REPO ?= https://github.com/aeron-io/aeron.git
AERON_UPSTREAM_REF ?= release/1.50.x
AERON_UPSTREAM_DIR ?= vendor/aeron
ZIG_UPSTREAM_REPO ?= https://codeberg.org/ziglang/zig
ZIG_UPSTREAM_REF ?= 0.15.2
ZIG_UPSTREAM_DIR ?= vendor/zig
INTEROP_ZIG_BUILD_ENV_IMAGE ?= harus-aeron-zig-build-env:latest

ifeq ($(origin CONTAINER_ENGINE), undefined)
CONTAINER_ENGINE := $(shell if command -v docker >/dev/null 2>&1; then printf '%s' 'docker'; \
	elif command -v podman >/dev/null 2>&1; then printf '%s' 'podman'; \
	else printf '%s' 'docker'; fi)
endif

.PHONY: fmt fmt-check build test lint check clean run tutorial-check lesson-lint \
       fuzz bench stress \
       nix-image k8s-up k8s-down k8s-status k8s-logs colima-up colima-down \
       setup setup-interop setup-interop-base setup-upstream-aeron setup-upstream-zig \
       interop interop-smoke interop-status interop-preflight test-protocol test-driver test-archive test-cluster test-scenarios examples status

fmt:
	$(NIX_RUN) zig fmt src/ build.zig
	$(NIX_RUN) prettier --write "**/*.{json,yaml,yml}"

fmt-check:
	$(NIX_RUN) zig fmt --check src/ build.zig
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

examples:  ## Build all examples
	$(NIX_RUN) zig build examples

lint: fmt-check

lesson-lint:  ## Verify all LESSON annotation slugs have a matching docs/tutorial/ chapter file
	bash scripts/lesson-lint.sh

check: fmt-check build test test-scenarios lesson-lint  ## Full check: fmt + build + all tests

status:  ## Show parity and chapter status from JSONL sources
	@echo "=== Parity Gaps ==="
	@jq -r '"\(.layer): \(.completeness_pct)% — gaps: \(.gaps | join(", "))"' .agents/registry/parity_status.jsonl
	@echo ""
	@echo "=== Upstream Map — pending ==="
	@jq -r 'select(.status == "pending") | "\(.layer)/\(.upstream_class)"' test/upstream_map.jsonl
	@echo ""
	@echo "=== Chapter Status — incomplete ==="
	@jq -r 'select(.status != "done") | "\(.id) \(.slug): \(.status)"' .agents/registry/chapter_status.jsonl

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

setup-interop-base:
	@$(MAKE) interop-preflight
	@if $(CONTAINER_ENGINE) image inspect "$(INTEROP_ZIG_BUILD_ENV_IMAGE)" >/dev/null 2>&1; then \
		echo "Using cached interop build env image: $(INTEROP_ZIG_BUILD_ENV_IMAGE)"; \
	else \
		echo "Building interop build env image: $(INTEROP_ZIG_BUILD_ENV_IMAGE)"; \
		$(CONTAINER_ENGINE) build -f deploy/Dockerfile --target build-env -t "$(INTEROP_ZIG_BUILD_ENV_IMAGE)" .; \
	fi

setup-upstream-aeron:
	@mkdir -p vendor
	@if [ -d "$(AERON_UPSTREAM_DIR)/.git" ]; then \
		git -C "$(AERON_UPSTREAM_DIR)" fetch --depth 1 origin "$(AERON_UPSTREAM_REF)"; \
		git -C "$(AERON_UPSTREAM_DIR)" checkout --detach FETCH_HEAD; \
	else \
		rm -f "$(AERON_UPSTREAM_DIR)"; \
		git clone --depth 1 --branch "$(AERON_UPSTREAM_REF)" "$(AERON_UPSTREAM_REPO)" "$(AERON_UPSTREAM_DIR)"; \
	fi

setup-upstream-zig:
	@mkdir -p vendor
	@if [ -d "$(ZIG_UPSTREAM_DIR)/.git" ]; then \
		git -C "$(ZIG_UPSTREAM_DIR)" fetch --depth 1 origin "$(ZIG_UPSTREAM_REF)"; \
		git -C "$(ZIG_UPSTREAM_DIR)" checkout --detach FETCH_HEAD; \
	else \
		rm -f "$(ZIG_UPSTREAM_DIR)"; \
		git init "$(ZIG_UPSTREAM_DIR)" >/dev/null 2>&1; \
		git -C "$(ZIG_UPSTREAM_DIR)" remote add origin "$(ZIG_UPSTREAM_REPO)"; \
		git -C "$(ZIG_UPSTREAM_DIR)" fetch --depth 1 origin "$(ZIG_UPSTREAM_REF)"; \
		git -C "$(ZIG_UPSTREAM_DIR)" checkout --detach FETCH_HEAD; \
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

ifeq ($(origin COMPOSE), undefined)
COMPOSE := $(shell if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then printf '%s' 'docker compose'; \
	elif command -v podman-compose >/dev/null 2>&1; then printf '%s' 'podman-compose'; \
	else printf '%s' 'docker compose'; fi)
endif

interop-preflight:
	@if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then \
		docker info >/dev/null 2>&1 || { \
			echo "Docker daemon is not reachable. Start any Docker-compatible daemon, or point DOCKER_HOST at a live daemon."; \
			exit 1; \
		}; \
	elif command -v podman-compose >/dev/null 2>&1; then \
		command -v podman >/dev/null 2>&1 || { \
			echo "podman-compose is installed but podman is not available."; \
			exit 1; \
		}; \
		podman info >/dev/null 2>&1 || { \
			echo "Podman is not reachable. Start the podman machine or set COMPOSE=\"docker compose\"."; \
			exit 1; \
		}; \
	else \
		echo "No supported compose runtime found. Install a Compose-compatible client such as Docker Compose or podman-compose."; \
		exit 1; \
	fi

interop:  ## Run full interop test suite (100 messages, all scenarios)
	@$(MAKE) interop-preflight
	@$(MAKE) setup-interop-base
	AERON_VERSION=1.50.2 ZIG_BUILD_ENV_IMAGE=$(INTEROP_ZIG_BUILD_ENV_IMAGE) MSG_COUNT=100 $(COMPOSE) -f deploy/docker-compose.ci.yml up --build --abort-on-container-exit --exit-code-from java-client

interop-smoke:  ## Run quick smoke interop test (10 messages, CI-friendly)
	@$(MAKE) interop-preflight
	@$(MAKE) setup-interop-base
	AERON_VERSION=1.50.2 ZIG_BUILD_ENV_IMAGE=$(INTEROP_ZIG_BUILD_ENV_IMAGE) MSG_COUNT=10 $(COMPOSE) -f deploy/docker-compose.ci.yml up --build --abort-on-container-exit --exit-code-from java-client

interop-status:  ## Show status of running interop jobs
	@echo "=== Interop Jobs ==="
	kubectl get jobs -n aeron -l 'app.kubernetes.io/part-of in (interop,interop-smoke)' -o wide 2>/dev/null || \
		echo "(no interop jobs found — run 'make interop' or 'make interop-smoke')"
	@echo ""
	@echo "=== Interop Pods ==="
	kubectl get pods -n aeron -l 'app.kubernetes.io/part-of in (interop,interop-smoke)' -o wide 2>/dev/null || true
