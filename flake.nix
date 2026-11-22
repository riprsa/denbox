{
  description = "denbox: Linux workspaces defined by a flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
        (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # An environment imports this into each box's Home Manager configuration.
      homeManagerModules.default = ./kit/nix/modules;

      packages = forAllSystems (pkgs: rec {
        denbox-api = pkgs.callPackage ./kit/nix/packages/denbox-api.nix { };
        default = denbox-api;
      });

      checks = forAllSystems (pkgs: {
        # The package build runs the Go tests.
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) denbox-api;
        modules = pkgs.callPackage ./kit/nix/checks/modules.nix {
          inherit home-manager;
          module = self.homeManagerModules.default;
        };
      });
    };
}
