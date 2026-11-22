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
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      # The kit's nixpkgs. Claude Code is the one unfree package the kit
      # ships; it is allowed here and nowhere else.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";
      };
      forAllSystems = f: lib.genAttrs systems (system: f (pkgsFor system));

      # A box: the Home Manager activation package of a box's module on top
      # of the kit's modules, with the box's denbox.follow, its denbox.host
      # and its evaluated configuration attached (docs/design.md,
      # Environment contract).
      mkBox = system: module:
        let
          home = home-manager.lib.homeManagerConfiguration {
            pkgs = pkgsFor system;
            modules = [
              self.homeManagerModules.default
              {
                home.username = lib.mkDefault "root";
                home.homeDirectory = lib.mkDefault "/root";
                # Fixed for every box; changing it would change existing boxes.
                home.stateVersion = lib.mkDefault "26.05";
              }
              module
            ];
          };
        in
        home.activationPackage // { inherit (home.config.denbox) follow host; inherit (home) config; };
    in
    {
      # An environment imports this into each box's Home Manager configuration.
      homeManagerModules.default = ./kit/nix/modules;

      # Box name to Home Manager module, to `{ <system>.boxes.<name> = <box>; }`,
      # the value of an environment's legacyPackages.
      lib.mkBoxes = boxes: lib.genAttrs systems (system: {
        boxes = lib.mapAttrs (_: mkBox system) boxes;
      });

      # `mkBundle pkgs { <name> = { background, content, pages }; }`: the
      # bundle file the extension loads from a source, built from parts with
      # file paths in place of text (docs/design.md, Browser). A repository
      # that is a source commits the result.
      lib.mkBundle = pkgs: parts: pkgs.callPackage ./kit/nix/packages/browser-bundle.nix { inherit parts; };

      packages = forAllSystems (pkgs: rec {
        denbox-api = pkgs.callPackage ./kit/nix/packages/denbox-api.nix { };
        t3 = pkgs.callPackage ./kit/nix/packages/t3.nix { };
        codex = pkgs.callPackage ./kit/nix/packages/codex.nix { };
        claude = pkgs.callPackage ./kit/nix/packages/claude.nix { };
        runtime = pkgs.callPackage ./kit/nix/packages/runtime.nix { };
        default = denbox-api;
      });

      templates.default = {
        path = ./template;
        description = "An environment with one box";
      };

      checks = forAllSystems (pkgs:
        let system = pkgs.stdenv.hostPlatform.system; in {
          # The package builds run the Go tests and the agents' version checks.
          inherit (self.packages.${system}) denbox-api t3 codex claude;
          modules = pkgs.callPackage ./kit/nix/checks/modules.nix {
            inherit home-manager;
            module = self.homeManagerModules.default;
          };
          bundle = pkgs.callPackage ./kit/nix/checks/bundle.nix { inherit (self.lib) mkBundle; };
          boxes = pkgs.callPackage ./kit/nix/checks/boxes.nix {
            inherit system;
            kit = self;
          };
          host = pkgs.callPackage ./kit/nix/checks/host.nix {
            inherit system;
            kit = self;
          };
        });
    };
}
