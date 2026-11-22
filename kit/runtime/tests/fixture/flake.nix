# The environment of the end-to-end test: the box contract without the kit
# or the network. boxes.test is a plain derivation whose activate links one
# service, worker, which writes "<version> <extra>" to ~/worker-version.
# extra is pinned to the branch old; follow points it at main.
{
  inputs.extra = { url = "git+file:///srv/extra?ref=old"; flake = false; };

  outputs = { self, extra }:
    let
      version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ./version);
      value = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile "${extra}/value");
      box = system: derivation {
        name = "denbox-test-box";
        inherit system;
        builder = "/bin/sh";
        # The build sees no PATH; every command is absolute.
        args = [ "-c" ''
          ${if builtins.pathExists ./broken then "exit 1" else ""}
          /bin/mkdir -p $out/services/worker
          /bin/cat > $out/services/worker/run <<EOF
          #!/bin/sh
          echo '${version} ${value}' > "\$HOME/worker-version"
          echo start >> "\$HOME/worker-starts"
          exec /bin/sleep 100000
          EOF
          /bin/cat > $out/activate <<EOF
          #!/bin/sh
          set -eu
          /bin/mkdir -p "\$HOME/.config/denbox/services"
          /bin/ln -sfn $out/services/worker "\$HOME/.config/denbox/services/worker"
          EOF
          /bin/chmod +x $out/activate $out/services/worker/run
        '' ];
      } // { follow.extra = "git+file:///srv/extra?ref=main"; };
    in
    {
      legacyPackages = builtins.listToAttrs (map
        (system: { name = system; value.boxes.test = box system; })
        [ "x86_64-linux" "aarch64-linux" ]);
    };
}
