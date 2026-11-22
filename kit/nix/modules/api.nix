# denbox-api, the box's state behind the browser panel, as the supervised
# service denbox-api. It serves data only; the extension's code comes from Git.
{ config, lib, pkgs, kit, ... }:
let
  cfg = config.denbox;
  api = kit.denbox-api;
in
{
  options.denbox.api = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run denbox-api.";
    };
    # The box's front door routes the panel's domain here.
    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:48099";
      description = "Where denbox-api listens.";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      description = "The network interface whose traffic the panel shows.";
    };
  };

  # denbox-api calls `denbox service`, found on the box's PATH.
  config = lib.mkIf cfg.api.enable {
    denbox.services.denbox-api = pkgs.writeShellScript "denbox-api-service" ''
      export PATH=${lib.makeBinPath [ pkgs.iproute2 pkgs.coreutils ]}:$PATH
      export DENBOX_API_ADDRESS=${lib.escapeShellArg cfg.api.address}
      export DENBOX_INTERFACE=${lib.escapeShellArg cfg.api.interface}
      export DENBOX_OPTIONAL_SERVICES=${lib.escapeShellArg (lib.concatStringsSep " " cfg.optionalServices)}
      export DENBOX_OPTIONAL_SERVICES_DIR="$HOME/.local/state/denbox/optional-services"
      exec ${lib.getExe api}
    '';
  };
}
