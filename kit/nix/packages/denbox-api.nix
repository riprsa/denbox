{ buildGoModule, lib }:
buildGoModule {
  pname = "denbox-api";
  version = "0.1.0";
  # Only the Go sources, so a change elsewhere in the repository does not rebuild it.
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [ ../../go.mod ../../api ../../cmd ];
  };
  # No dependencies outside the standard library. Every package is built and
  # tested; cmd/denbox-api is the only binary.
  vendorHash = null;
  env.CGO_ENABLED = "0";
  # Go writes telemetry under $HOME; without a sandbox, as in a box, that would
  # be a shared /homeless-shelter that fails every later build.
  preBuild = ''
    export HOME="$TMPDIR"
  '';
  ldflags = [ "-s" "-w" ];
  meta.mainProgram = "denbox-api";
}
