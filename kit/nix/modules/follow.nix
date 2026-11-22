# Inputs the runtime overrides at every sync: `nix build` gets
# `--override-input NAME REF` for each entry (docs/design.md, Sync).
# mkBoxes exposes the value as `<box>.follow`.
{ lib, ... }:
{
  options.denbox.follow = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = { denbox = "github:riprsa/denbox"; };
    description = "Flake input name to the flake reference the box builds it from.";
  };
}
