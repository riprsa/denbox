# What a box asks of its host: the template's box asks for what the standard
# deployment gives, a box that sets requirements and secrets gets them in
# `<box>.host`, and a value deploy/render would refuse fails evaluation. Then runs the
# golden-file tests of deploy/render.
{ system, kit, lib, runCommand, bash, diffutils, jq }:
let
  golden = name: builtins.fromJSON (builtins.readFile ../../../deploy/tests/render/${name}.json);
  boxes = (kit.lib.mkBoxes {
    # The API on loopback and no T3: nothing to publish.
    quiet = { };
    asks = {
      denbox.t3.enable = true;
      denbox.api.enable = false;
      denbox.host = {
        ports.t3.hostPort = 13773;
        ports.web = { port = 8080; address = "0.0.0.0"; };
        memory = "8g";
        cpus = 0.5;
        pids = 4096;
        tmpSize = "4g";
        shmSize = "2g";
        devices = [ "/dev/net/tun" ];
        capabilities = [ "NET_ADMIN" ];
        binds = [
          { source = "/srv/data"; target = "/data"; }
          { source = "/srv/cache"; target = "/root/cache"; readOnly = false; }
        ];
        dns = [ "1.1.1.1" "9.9.9.9" ];
        secrets.token.description = "Token of the example API";
        secrets.key = { target = "/etc/example/key"; allowEmpty = true; description = "Key of the example service; empty to log in by hand"; };
      };
    };
    badMemory.denbox.host.memory = "4 GB";
    badCapability.denbox.host.capabilities = [ "CAP_NET_ADMIN" ];
    badAddress.denbox.host.ports.web = { port = 80; address = "localhost"; };
    badSecretName.denbox.host.secrets.git_token.description = "a";
    badDescription.denbox.host.secrets.a.description = "two\nlines";
    secretOnBootstrap.denbox.host.secrets.a = { target = "/run/secrets/denbox_bootstrap"; description = "a"; };
    sameTarget.denbox.host = {
      secrets.a = { target = "/data"; description = "a"; };
      binds = [{ source = "/srv/data"; target = "/data"; }];
    };
    twice.denbox.host.ports = {
      a = { port = 80; hostPort = 8080; address = "0.0.0.0"; };
      b = { port = 81; hostPort = 8080; };
    };
  }).${system}.boxes;
  template = ((import ../../../template/flake.nix).outputs { denbox = kit; }).legacyPackages.${system}.boxes.main;
  refused = box: !(builtins.tryEval (builtins.deepSeq box.host true)).success;
in
assert template.host == golden "default";
assert boxes.quiet.host.ports == { };
assert boxes.asks.host == golden "asks";
assert lib.all refused (with boxes; [ badMemory badCapability badAddress twice
  badSecretName badDescription secretOnBootstrap sameTarget ]);
runCommand "denbox-host-check" { nativeBuildInputs = [ bash diffutils jq ]; } ''
  cp -R ${../../../deploy} deploy
  chmod -R u+w deploy
  patchShebangs deploy
  deploy/tests/render.sh
  touch "$out"
''
