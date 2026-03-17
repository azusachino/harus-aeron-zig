NIX_RUN := $(if $(filter $(IN_NIX_SHELL),),nix develop --command ,)

.PHONY: fmt fmt-check build test lint check clean run tutorial-check

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
	rm -rf zig-out .zig-cache
