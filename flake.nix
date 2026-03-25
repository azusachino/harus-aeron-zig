{
  description = "Aeron protocol implementation in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Linux pkgs for container image contents
        linuxSystem = builtins.replaceStrings [ "darwin" ] [ "linux" ] system;
        linuxPkgs = nixpkgs.legacyPackages.${linuxSystem};

        # Cross-compiled Zig binary targeting Linux aarch64
        # Zig handles cross-compilation natively — no toolchain setup needed
        zigBuildLinux = pkgs.stdenv.mkDerivation {
          pname = "harus-aeron-zig";
          version = "0.3.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp -r zig-out/bin/* $out/bin/ 2>/dev/null || true
            if [ ! "$(ls -A $out/bin 2>/dev/null)" ]; then
              echo "No binaries produced — library-only build"
            fi
          '';
          dontPatchELF = true;
          dontFixup = true;
        };

        # OCI image via nixpkgs dockerTools (works on macOS, no daemon needed)
        ociImage = pkgs.dockerTools.buildImage {
          name = "harus-aeron-zig";
          tag = "latest";

          copyToRoot = pkgs.buildEnv {
            name = "image-root";
            paths = [ zigBuildLinux ];
            pathsToLink = [ "/bin" ];
          };

          config = {
            Cmd = [ "/bin/aeron-driver" ];
            Env = [ "AERON_DIR=/dev/shm/aeron" ];
            Volumes = { "/dev/shm" = {}; };
          };
        };
      in
      {
        packages = {
          default = zigBuildLinux;
          oci = ociImage;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            zig    # 0.15.2 — pinned via flake.lock
            zls
            nodePackages.prettier
            skopeo  # OCI image transport (push/pull without Docker)
            podman-compose  # local CI interop smoke (podman-compose / podman compose)
          ];

          shellHook = ''
            export IN_NIX_SHELL=1
          '';
        };
      });
}
