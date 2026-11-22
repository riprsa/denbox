# T3 Code as the supervised service t3, started through the secrets provider
# with consumer t3.
{ config, lib, pkgs, kit, ... }:
let
  cfg = config.denbox.t3;
  inherit (config.denbox.secrets) provider;
  json = pkgs.formats.json { };
  # Merged recursively into T3's settings.json on every start; T3 keeps the
  # rest. A broken file is left alone so T3 still starts.
  mergeSettings = lib.optionalString (cfg.settings != { }) ''
    settings="$T3CODE_HOME/userdata/settings.json"
    mkdir -p "''${settings%/*}"
    if (umask 077; [[ -s "$settings" ]] || echo '{}' > "$settings"
      ${lib.getExe pkgs.jq} --slurpfile ours ${json.generate "t3-settings.json" cfg.settings} \
        '. * $ours[0]' "$settings" > "$settings.new"); then
      mv -f "$settings.new" "$settings"
    else
      rm -f "$settings.new"
      echo "denbox: could not merge denbox.t3.settings into $settings" >&2
    fi
  '';
in
{
  options.denbox.t3 = {
    enable = lib.mkEnableOption "T3 Code as the service t3";
    package = lib.mkOption {
      type = lib.types.package;
      default = kit.t3;
      defaultText = lib.literalExpression "kit.t3";
      description = "The T3 Code package; override to patch or repin.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3773;
      description = "Port T3 listens on.";
    };
    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address T3 listens on.";
    };
    projects = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Projects";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/Projects"'';
      description = "Directory T3 opens projects from; created on start.";
    };
    settings = lib.mkOption {
      inherit (json) type;
      default = { };
      description = "Merged into T3's settings.json on every start.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    # The profile's bin puts the box's tools and agent commands on T3's PATH.
    denbox.services.t3 = pkgs.writeShellScript "denbox-t3-service" ''
      export PATH=${config.home.profileDirectory}/bin:$PATH
      export CODEX_HOME="$HOME/.codex" T3CODE_HOME="$HOME/.t3"
      ${mergeSettings}
      mkdir -p ${lib.escapeShellArg cfg.projects}
      exec ${provider} t3 -- ${lib.getExe cfg.package} serve \
        --host ${lib.escapeShellArg cfg.host} --port ${toString cfg.port} \
        --base-dir "$T3CODE_HOME" ${lib.escapeShellArg cfg.projects}
    '';
  };
}
