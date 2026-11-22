# Builds a bundle file from parts given as files: the same shape as a bundle
# part with each file path replaced by the file's text (docs/design.md,
# Browser). denbox.lib.mkBundle calls it. Every field of a part may be left
# out, and so may a page's html or js.
{ lib, runCommand, jq, parts }:
let
  # A part with every field present: background null, content and pages empty.
  full = part: {
    background = part.background or null;
    content = part.content or [ ];
    pages = lib.mapAttrs (_: page: { html = page.html or null; js = page.js or null; }) (part.pages or { });
  };
  normal = lib.mapAttrs (_: full) parts;
  files = part:
    lib.optional (part.background != null) part.background
    ++ map (script: script.js) part.content
    ++ lib.filter (file: file != null) (lib.concatMap (page: [ page.html page.js ]) (lib.attrValues part.pages));
  # Paths as strings; interpolation copies local files to the store.
  text = file: if file == null then null else "${file}";
  spec = lib.mapAttrs (_: part: {
    background = text part.background;
    content = map (script: { inherit (script) matches; js = text script.js; }) part.content;
    pages = lib.mapAttrs (_: page: { html = text page.html; js = text page.js; }) part.pages;
  }) normal;
in
runCommand "denbox-bundle.json" {
  nativeBuildInputs = [ jq ];
  spec = builtins.toJSON spec;
  files = lib.unique (map text (lib.concatMap files (lib.attrValues normal)));
  passAsFile = [ "spec" ];
} ''
  # texts: file path to its contents.
  for file in $files; do
    jq -n --arg path "$file" --rawfile text "$file" '{ ($path): $text }'
  done | jq -s 'add // {}' > texts.json
  # A null field (no background, a page without html or js) is left out.
  jq --slurpfile texts texts.json '
    $texts[0] as $t
    | { version: 1, parts: map_values(
        (if .background == null then del(.background) else .background |= $t[.] end)
        | .content |= map(.js |= $t[.])
        | .pages |= map_values(with_entries(select(.value != null) | .value |= $t[.]))) }
  ' "$specPath" > "$out"
''
