{ buildGoModule, lib }:
buildGoModule {
  pname = "denbox-api";
  version = "0.1.0";
  # Only the Go sources, so a change elsewhere in the repository does not rebuild it.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [ ../go.mod ../api ../cmd ];
  };
  # No dependencies outside the standard library.
  vendorHash = null;
  subPackages = [ "cmd/denbox-api" ];
  env.CGO_ENABLED = "0";
  ldflags = [ "-s" "-w" ];
  meta.mainProgram = "denbox-api";
}
