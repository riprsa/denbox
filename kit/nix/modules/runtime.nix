# The runtime in every box: activation installs it as ~/.nix-profile/bin/denbox,
# and the image starts that copy from then on.
{ pkgs, ... }:
{
  home.packages = [ (pkgs.callPackage ../packages/runtime.nix { }) ];
}
