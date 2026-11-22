# The kit's Home Manager modules, one file per option group. An environment
# gets them as denbox.homeManagerModules.default.
{
  imports = [
    ./services.nix
    ./api.nix
    ./browser.nix
    ./secrets.nix
    ./follow.nix
    ./tools.nix
    ./t3.nix
    ./agents.nix
  ];
}
