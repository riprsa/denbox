# The kit's Home Manager modules, one file per option group. An environment
# gets them as denbox.homeManagerModules.default.
{
  imports = [
    ./name.nix
    ./services.nix
    ./api.nix
    ./secrets.nix
    ./follow.nix
    ./apply.nix
    ./host.nix
    ./tools.nix
    ./t3.nix
    ./agents.nix
    ./tailscale.nix
    ./kit.nix
    ./runtime.nix
  ];
}
