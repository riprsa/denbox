# Builds a bundle with lib.mkBundle from one full part and one bare part and
# compares it with the bundle it must be.
{ pkgs, lib, mkBundle, runCommand, jq, writeText }:
let
  bundle = mkBundle pkgs {
    greet = {
      background = writeText "background.js" "start()";
      content = [{ matches = [ "https://example.com/*" ]; js = writeText "content.js" "greet()"; }];
      pages.options = { html = writeText "options.html" "<p>hi</p>"; js = writeText "options.js" "show()"; };
      pages.plain.html = writeText "plain.html" "<p>plain</p>";
    };
    bare = { };
  };
  expected = builtins.toJSON {
    version = 1;
    parts = {
      greet = {
        background = "start()";
        content = [{ matches = [ "https://example.com/*" ]; js = "greet()"; }];
        pages.options = { html = "<p>hi</p>"; js = "show()"; };
        pages.plain.html = "<p>plain</p>";
      };
      bare = { content = [ ]; pages = { }; };
    };
  };
in
runCommand "denbox-bundle-check" { nativeBuildInputs = [ jq ]; } ''
  jq -e --argjson expected ${lib.escapeShellArg expected} '. == $expected' ${bundle} \
    || { echo "unexpected bundle:" >&2; cat ${bundle} >&2; exit 1; }
  touch "$out"
''
