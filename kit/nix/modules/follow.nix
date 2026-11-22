# Inputs the runtime overrides at every sync: it resolves each REF to its
# current revision and builds with `--override-input NAME <REF at that
# revision>` (docs/design.md, Sync).
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
