ARG ZIG_BUILD_ENV_IMAGE=nixos/nix:latest

FROM ${ZIG_BUILD_ENV_IMAGE} AS build-env
ARG ZIG_BUILD_ENV_IMAGE
WORKDIR /src
COPY flake.nix flake.lock ./
RUN if [ "${ZIG_BUILD_ENV_IMAGE}" = "nixos/nix:latest" ]; then \
      nix --extra-experimental-features nix-command --extra-experimental-features flakes develop --command sh -lc 'zig version >/dev/null && prettier --version >/dev/null'; \
    fi

FROM build-env AS builder
COPY . .
RUN nix --extra-experimental-features nix-command --extra-experimental-features flakes develop --command make build

FROM builder
WORKDIR /app
COPY --from=builder /src/zig-out/bin/aeron-driver /app/aeron-driver
COPY --from=builder /src/deploy/entrypoint-driver.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
EXPOSE 20121/udp
ENTRYPOINT ["/app/entrypoint.sh"]
