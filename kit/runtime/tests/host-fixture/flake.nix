# The environment of the machine's end-to-end test: a real box from
# lib.mkBoxes for the user boxuser, with the tools and the API off. Its one
# service, worker, writes the file version to ~/worker-version. A file named
# broken makes the build fail. host.sh points the denbox input at the kit.
{
  inputs.denbox.url = "path:@KIT@";

  outputs = { denbox, ... }:
    let
      version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ./version);
    in
    {
      legacyPackages = denbox.lib.mkBoxes {
        test = { pkgs, lib, ... }: {
          home.username = "boxuser";
          home.homeDirectory = "/home/boxuser";
          denbox.tools.enable = false;
          denbox.api.enable = false;
          denbox.services.worker = pkgs.writeShellScript "worker" ''
            echo ${version} > "$HOME/worker-version"
            echo start >> "$HOME/worker-starts"
            exec ${pkgs.coreutils}/bin/sleep infinity
          '';
          home.file = lib.optionalAttrs (builtins.pathExists ./broken) {
            broken.source = pkgs.runCommand "broken" { } "exit 1";
          };
        };
      };
    };
}
