# Builds bundle.json from denbox.browser.parts: the same shape with each file
# path replaced by the file's text (docs/design.md, Browser).
{ lib, runCommand, jq, parts }:
let
  files = part:
    lib.optional (part.background != null) part.background
    ++ map (script: script.js) part.content
    ++ lib.concatMap (page: [ page.html page.js ]) (lib.attrValues part.pages);
  # Paths as strings; interpolation copies local files to the store.
  spec = lib.mapAttrs (_: part: {
    background = if part.background == null then null else "${part.background}";
    content = map (script: { inherit (script) matches; js = "${script.js}"; }) part.content;
    pages = lib.mapAttrs (_: page: { html = "${page.html}"; js = "${page.js}"; }) part.pages;
  }) parts;
in
runCommand "denbox-bundle.json" {
  nativeBuildInputs = [ jq ];
  spec = builtins.toJSON spec;
  files = lib.unique (map (file: "${file}") (lib.concatMap files (lib.attrValues parts)));
  passAsFile = [ "spec" ];
} ''
  # texts: file path to its contents.
  for file in $files; do
    jq -n --arg path "$file" --rawfile text "$file" '{ ($path): $text }'
  done | jq -s 'add // {}' > texts.json
  jq --slurpfile texts texts.json '
    $texts[0] as $t
    | { version: 1, parts: map_values(
        (if .background == null then del(.background) else .background |= $t[.] end)
        | .content |= map(.js |= $t[.])
        | .pages |= map_values(.html |= $t[.] | .js |= $t[.])) }
  ' "$specPath" > "$out"
''
