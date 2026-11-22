# Builds a minimal box with one service and one optional service, and checks
# the files the modules produce.
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
in
runCommand "denbox-modules-check" { } ''
  services=${box.activationPackage}/home-files/.config/denbox/services
  fail() { echo "$*" >&2; exit 1; }

  # A plain service runs its executable; an optional one runs it through a gate.
  [[ $(readlink "$services/hello/run") == ${services.hello} ]] || fail "hello: wrong run link"
  gate=$(readlink "$services/editor/run")
  [[ $gate != ${services.editor} ]] && grep -q 'exec ${services.editor}$' "$gate" || fail "editor: not gated"
  [[ $(readlink "$services/denbox-api/run") == ${services.denbox-api} ]] || fail "denbox-api: wrong run link"
  touch "$out"
''
