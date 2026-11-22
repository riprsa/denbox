# Supervised services. The runtime supervises every
# ~/.config/denbox/services/NAME/run with s6.
{ config, lib, pkgs, ... }:
let
  cfg = config.denbox;
  # An optional service runs only while its marker
  # ~/.local/state/denbox/optional-services/NAME exists. Without it the run
  # script asks s6 to keep the service down and exits, so neither a box
  # restart nor an activation starts it. denbox-api toggles markers.
  gate = name: run: pkgs.writeShellScript "denbox-optional-${name}" ''
    if [[ ! -e "$HOME/.local/state/denbox/optional-services/"${lib.escapeShellArg name} ]]; then
      ${pkgs.s6}/bin/s6-svc -d .
      exit 0
    fi
    exec ${run}
  '';
in
{
  options.denbox = {
    # Name to executable; the executable becomes the service's run script.
    services = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = "Executables the runtime supervises, by service name.";
    };
    # Names from denbox.services; denbox-api switches them on and off.
    optionalServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Services that stay off until switched on; the choice survives restarts.";
    };
  };

  config = {
    assertions = [{
      assertion = lib.all (name: cfg.services ? ${name}) cfg.optionalServices;
      message = "denbox.optionalServices names services missing from denbox.services.";
    }];

    home.file = lib.mapAttrs' (name: run:
      lib.nameValuePair ".config/denbox/services/${name}" {
        source = pkgs.runCommand "denbox-service-${name}" { } ''
          mkdir -p "$out"
          ln -s ${if lib.elem name cfg.optionalServices then gate name run else run} "$out/run"
        '';
      }
    ) cfg.services;
  };
}
