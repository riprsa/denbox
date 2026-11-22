# The runtime in every box: activation installs it as ~/.nix-profile/bin/denbox,
# and the image starts that copy from then on.
{ kit, ... }:
{
  home.packages = [ kit.runtime ];
}
