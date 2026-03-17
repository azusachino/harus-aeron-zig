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
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            zig    # 0.15.2 — pinned via flake.lock (nixpkgs 5b2c2d8, 2026-03-16)
            zls
            nodePackages.prettier
          ];

          shellHook = ''
            export IN_NIX_SHELL=1
          '';
        };
      });
}
