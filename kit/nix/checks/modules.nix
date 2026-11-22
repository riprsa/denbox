# Builds a minimal box with one service, one optional service and one browser
# part, and checks the files the modules produce.
{ pkgs, lib, home-manager, module, runCommand, jq, writeShellScript, writeText }:
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
        denbox.browser.parts.greet = {
          background = writeText "background.js" "start()";
          content = [{ matches = [ "https://example.com/*" ]; js = writeText "content.js" "greet()"; }];
          pages.options = { html = writeText "options.html" "<p>hi</p>"; js = writeText "options.js" "show()"; };
        };
      }
    ];
  };
  inherit (box.config.denbox) services;
  expected = builtins.toJSON {
    background = "start()";
    content = [{ matches = [ "https://example.com/*" ]; js = "greet()"; }];
    pages.options = { html = "<p>hi</p>"; js = "show()"; };
  };
in
runCommand "denbox-modules-check" { nativeBuildInputs = [ jq ]; } ''
  services=${box.activationPackage}/home-files/.config/denbox/services
  fail() { echo "$*" >&2; exit 1; }

  # A plain service runs its executable; an optional one runs it through a gate.
  [[ $(readlink "$services/hello/run") == ${services.hello} ]] || fail "hello: wrong run link"
  gate=$(readlink "$services/editor/run")
  [[ $gate != ${services.editor} ]] && grep -q 'exec ${services.editor}$' "$gate" || fail "editor: not gated"
  [[ $(readlink "$services/denbox-api/run") == ${services.denbox-api} ]] || fail "denbox-api: wrong run link"

  # denbox-api serves the bundle built from the part, next to the kit's panel.
  bundle=$(sed -n 's/^export DENBOX_BUNDLE=//p' ${services.denbox-api})
  [[ -n $bundle ]] || fail "denbox-api: no bundle"
  jq -e --argjson expected ${lib.escapeShellArg expected} \
    '.version == 1 and .parts.greet == $expected and (.parts.panel.pages.panel | (.html | length > 0) and (.js | length > 0))' \
    "$bundle" || fail "bundle: unexpected content"
  touch "$out"
''
