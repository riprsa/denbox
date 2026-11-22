{
  description = "denbox: a long-lived, Nix-defined workspace for coding agents";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ]
        (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # An environment imports this into its Home Manager configuration.
      homeManagerModules.default = ./kit/nix/home.nix;

      packages = forAllSystems (pkgs: rec {
        denbox-api = pkgs.callPackage ./kit/nix/denbox-api.nix { };
        default = denbox-api;
      });

      # The package build runs the Go tests.
      checks = forAllSystems (pkgs: { inherit (self.packages.${pkgs.system}) denbox-api; });
    };
}
