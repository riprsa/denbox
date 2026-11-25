# Builds a minimal box with one service and one optional service, and checks
# the files the modules produce. A second box asks for approval.
{ pkgs, home-manager, module, runCommand, writeShellScript }:
let
  box = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      module
      {
        home.username = "root";
        home.homeDirectory = "/root";
        home.stateVersion = "25.05";
        denbox.services.hello = writeShellScript "hello" "echo hello";
        denbox.services.editor = writeShellScript "editor" "echo editor";
        denbox.optionalServices = [ "editor" ];
      }
    ];
  };
  inherit (box.config.denbox) services;
  approving = box.extendModules { modules = [{ denbox.apply = "approve"; }]; };
in
runCommand "denbox-modules-check" { } ''
  services=${box.activationPackage}/home-files/.config/denbox/services
  fail() { echo "$*" >&2; exit 1; }

  # A plain service runs its executable; an optional one runs it through a gate.
  [[ $(readlink "$services/hello/run") == ${services.hello} ]] || fail "hello: wrong run link"
  gate=$(readlink "$services/editor/run")
  [[ $gate != ${services.editor} ]] && grep -q 'exec ${services.editor}$' "$gate" || fail "editor: not gated"
  [[ $(readlink "$services/denbox-api/run") == ${services.denbox-api} ]] || fail "denbox-api: wrong run link"
  # The mode the runtime reads from a built box.
  [[ $(cat ${box.activationPackage}/home-files/.config/denbox/apply) == auto ]] || fail "apply: not auto by default"
  [[ $(cat ${approving.activationPackage}/home-files/.config/denbox/apply) == approve ]] || fail "apply: not approve"
  touch "$out"
''
