# Home Manager module for a box: the supervised services and, with
# denbox.api.enable, the denbox-api service behind the browser panel.
#
# The runtime supervises every ~/.config/denbox/services/NAME/run with s6.
{ config, lib, pkgs, ... }:
let
  cfg = config.denbox;
  # An optional service runs only while its marker exists. Without it the run
  # script asks s6 to keep the service down and exits, so neither a box
  # restart nor an environment apply starts it. denbox-api toggles markers.
  gate = name: run: pkgs.writeShellScript "denbox-optional-${name}" ''
    if [[ ! -e ${lib.escapeShellArg "${cfg.optionalServicesDir}/${name}"} ]]; then
      /usr/bin/s6-svc -d "$PWD"
      exit 0
    fi
    exec ${run}
  '';
  api = pkgs.callPackage ./denbox-api.nix { };
in
{
  options.denbox = {
    services = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = "Executable service scripts supervised by the runtime.";
    };
    optionalServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Services that stay off until switched on; the choice survives restarts.";
    };
    optionalServicesDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/state/denbox/optional-services";
      readOnly = true;
      description = "One marker file per switched-on optional service.";
    };
    api = {
      enable = lib.mkEnableOption "denbox-api, the machine state behind the browser panel";
      address = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:48099";
        description = "Where denbox-api listens; the box's front door routes the panel's domain here.";
      };
      interface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "The network interface whose traffic the panel shows.";
      };
    };
  };

  config = lib.mkMerge [
    {
      home.file = lib.mapAttrs' (name: run:
        lib.nameValuePair ".config/denbox/services/${name}" {
          source = pkgs.runCommand "denbox-service-${name}" { } ''
            mkdir -p "$out"
            ln -s ${if lib.elem name cfg.optionalServices then gate name run else run} "$out/run"
          '';
        }
      ) cfg.services;
    }
    (lib.mkIf cfg.api.enable {
      denbox.services.denbox-api = pkgs.writeShellScript "denbox-api-service" ''
        export PATH=${lib.makeBinPath [ pkgs.iproute2 pkgs.coreutils ]}:/usr/local/bin:$PATH
        export DENBOX_API_ADDRESS=${lib.escapeShellArg cfg.api.address}
        export DENBOX_INTERFACE=${lib.escapeShellArg cfg.api.interface}
        export DENBOX_OPTIONAL_SERVICES=${lib.escapeShellArg (lib.concatStringsSep " " cfg.optionalServices)}
        export DENBOX_OPTIONAL_SERVICES_DIR=${lib.escapeShellArg cfg.optionalServicesDir}
        exec ${lib.getExe api}
      '';
    })
  ];
}
