# Who decides when a built environment reaches the box (docs/design.md,
# Sync). The runtime reads the mode from the applied box's own home files, so
# the mode in force is the one of the environment that runs, and a revision
# that changes it is applied by the mode it replaces. A box that applies on
# its own writes no file: no file means auto.
{ config, lib, ... }:
{
  options.denbox.apply = lib.mkOption {
    type = lib.types.enum [ "auto" "approve" ];
    default = "auto";
    description = ''
      auto: a sync activates what it built. approve: a sync builds, leaves the
      result pending and activates nothing until `denbox apply`.
    '';
  };

  config.home.file.".config/denbox/apply" = lib.mkIf (config.denbox.apply == "approve") { text = "approve"; };
}
