# T3 Code, the pinned nightly release archive from t3-sources.json
# (moved by ./update-pins). The archive holds the executable and its native
# addons; nothing is built.
{ lib, stdenv, fetchurl, nodejs_24, autoPatchelfHook, makeWrapper
, zlib, openssl, libsecret, vulkan-loader }:
let
  manifest = lib.importJSON ./t3-sources.json;
in
stdenv.mkDerivation {
  pname = "t3";
  inherit (manifest) version;
  src = fetchurl { inherit (manifest.sources.${stdenv.hostPlatform.system}) url hash; };
  dontBuild = true;
  dontStrip = true;
  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];
  # vulkan-loader serves the Vulkan backend of local dictation; it falls back
  # to the CPU without a GPU.
  buildInputs = [ stdenv.cc.cc.lib zlib openssl libsecret vulkan-loader ];
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/t3"
    cp -R . "$out/lib/t3/"
    # A box uses glibc; the unused musl addons, as packages (`*-linux-x64-musl`)
    # and as subdirectories (koffi's `musl_x64`), would fail autoPatchelf.
    find "$out/lib/t3/node_modules" -depth -type d -name '*musl*' -exec rm -rf {} +
    makeWrapper "$out/lib/t3/t3" "$out/bin/t3" --prefix PATH : ${lib.makeBinPath [ nodejs_24 ]}
    runHook postInstall
  '';
  meta = {
    description = "T3 Code, pinned by the denbox kit";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    platforms = builtins.attrNames manifest.sources;
    mainProgram = "t3";
  };
}
