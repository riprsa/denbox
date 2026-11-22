# denbox-api, the box's state behind the browser panel, as the supervised
# service denbox-api. It serves data only; the extension's code comes from Git.
{ config, lib, pkgs, kit, ... }:
let
  cfg = config.denbox;
  api = kit.denbox-api;
  # "HOST:PORT", the host possibly a bracketed IPv6 address.
  parts = builtins.match "(.*):([0-9]+)" cfg.api.address;
  listen = if parts == null then throw "denbox.api.address: \"${cfg.api.address}\" is not HOST:PORT" else {
    host = builtins.head parts;
    port = lib.toInt (lib.last parts);
  };
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
    # The host publishes the API's port when it listens beyond the box's
    # loopback; on loopback it is reachable only from inside the box.
    denbox.host.ports = lib.mkIf (!lib.hasPrefix "127." listen.host && listen.host != "localhost" && listen.host != "[::1]") {
      api.port = listen.port;
    };
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
