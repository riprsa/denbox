# Codex, the pinned npm launcher and platform package from codex-sources.json
# (moved by ./update-pins), run with Node.
{ lib, stdenvNoCC, fetchurl, nodejs_24, makeWrapper, ripgrep }:
let
  manifest = lib.importJSON ./codex-sources.json;
  platform = manifest.sources.${stdenvNoCC.hostPlatform.system};
  inherit (manifest.sources) launcher;
in
stdenvNoCC.mkDerivation {
  pname = "codex";
  inherit (manifest) version;
  src = fetchurl { inherit (launcher) url hash; };
  platformSrc = fetchurl { inherit (platform) url hash; };
  nativeBuildInputs = [ makeWrapper ];
  dontUnpack = true;
  dontStrip = true;
  dontPatchELF = true;
  installPhase = ''
    mkdir -p "$out/lib/node_modules/${launcher.directory}" \
      "$out/lib/node_modules/${platform.directory}" "$out/bin"
    tar -xzf "$src" --strip-components=1 -C "$out/lib/node_modules/${launcher.directory}"
    tar -xzf "$platformSrc" --strip-components=1 -C "$out/lib/node_modules/${platform.directory}"
    makeWrapper ${nodejs_24}/bin/node "$out/bin/codex" \
      --add-flags "$out/lib/node_modules/${launcher.directory}/bin/codex.js" \
      --prefix PATH : ${lib.makeBinPath [ ripgrep ]}
  '';
  meta = {
    description = "Codex, pinned by the denbox kit";
    homepage = "https://github.com/openai/codex";
    license = lib.licenses.asl20;
    platforms = builtins.filter (name: name != "launcher") (builtins.attrNames manifest.sources);
    mainProgram = "codex";
  };
}
