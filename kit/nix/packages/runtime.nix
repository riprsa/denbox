# The denbox command with the tools it calls on its own PATH. Nix itself
# comes from the host, so the runtime always uses the host's Nix.
{ lib, runCommand, bash, coreutils, gitMinimal, gnutar, jq, s6, util-linux }:
let
  tools = lib.makeBinPath [ coreutils gitMinimal gnutar jq s6 util-linux ];
in
runCommand "denbox-runtime" { meta.mainProgram = "denbox"; } ''
  install -Dm755 ${../../runtime/denbox} $out/libexec/denbox/denbox
  install -Dm755 ${../../runtime/askpass} $out/libexec/denbox/askpass
  substituteInPlace $out/libexec/denbox/denbox $out/libexec/denbox/askpass \
    --replace-fail '#!/usr/bin/env bash' '#!${bash}/bin/bash'
  substituteInPlace $out/libexec/denbox/denbox \
    --replace-fail "tools=''' # set by the package" 'tools=${tools}'
  mkdir -p $out/bin
  ln -s ../libexec/denbox/denbox $out/bin/denbox
''
