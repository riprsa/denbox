# The module argument `kit`: the kit's packages for the box's system, so any
# module of a box can wrap or patch them (`kit.claude`, `kit.codex`, `kit.t3`,
# `kit.runtime`, `kit.denbox-api`). The kit's own modules take their package
# defaults from it.
{ pkgs, ... }:
{
  _module.args.kit = {
    claude = pkgs.callPackage ../packages/claude.nix { };
    codex = pkgs.callPackage ../packages/codex.nix { };
    t3 = pkgs.callPackage ../packages/t3.nix { };
    runtime = pkgs.callPackage ../packages/runtime.nix { };
    denbox-api = pkgs.callPackage ../packages/denbox-api.nix { };
  };
}
