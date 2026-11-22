# The shell and command-line tools of every box, and ~/.config/denbox/shell,
# the executable `denbox shell` runs.
{ config, lib, pkgs, ... }:
let
  cfg = config.denbox;
in
{
  options.denbox.tools.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Install fish, starship, fzf, zoxide and the common command-line tools.";
  };

  config = lib.mkIf cfg.tools.enable {
    programs.fish = {
      enable = true;
      interactiveShellInit = "set -g fish_greeting";
    };
    programs.starship = {
      enable = true;
      # Every box is a container or a machine of its own; the marker is noise.
      settings.container.disabled = true;
    };
    programs.fzf.enable = true;
    programs.zoxide.enable = true;
    # Language toolchains vary by box; an environment adds the ones it needs.
    home.packages = with pkgs; [ git gh glab ripgrep fd jq curl openssh tmux neovim ];

    # fish with the secrets of consumer `shell`. A shell started before a
    # terminal is attached (as T3 does) would stall on fish's terminal
    # queries; the variable turns them off and also reaches nested fish.
    home.file.".config/denbox/shell".source = pkgs.writeShellScript "denbox-shell" ''
      export fish_features=no-query-term
      exec ${cfg.secrets.provider} shell -- ${lib.getExe config.programs.fish.package} "$@"
    '';
  };
}
