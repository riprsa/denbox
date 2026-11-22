# Evaluates the Tailscale module through lib.mkBoxes: off, on with every
# setting and two serve entries, and in userspace. Checks the service and
# serve configuration the options produce, what the box asks of its host
# (the tunnel device, NET_ADMIN and the key; in userspace the key only), and
# that a serve entry of a bad shape fails evaluation.
{ system, kit, lib, runCommand, tailscale }:
let
  boxes = (kit.lib.mkBoxes {
    off = { };
    on = {
      denbox.tailscale = {
        enable = true;
        loginServer = "https://headscale.example.com";
        tags = [ "tag:denbox" "tag:dev" ];
        ssh = true;
        acceptDns = false;
        serve.t3 = { port = 443; to = "http://127.0.0.1:3773"; };
        serve.api = { port = 8443; path = "/api"; https = false; to = "http://127.0.0.1:48099"; };
      };
    };
    userspace = {
      denbox.tailscale = { enable = true; userspace = true; hostname = "named"; };
    };
  }).${system}.boxes;
  inherit (boxes) off on userspace;
  run = box: box.config.denbox.services.tailscale;
  # configure: the script the service starts next to tailscaled.
  configure = box: builtins.head (builtins.match ".*(/nix/store/[^ ]*-denbox-tailscale-configure).*"
    (builtins.readFile (run box)));

  # Whether a box with these serve entries evaluates. Home Manager throws
  # for a failed assertion, so its message cannot be read here; the module's
  # messages name the option and what is wrong.
  evaluates = serve:
    let box = (kit.lib.mkBoxes { bad = { denbox.tailscale = { enable = true; inherit serve; }; }; }).${system}.boxes.bad;
    in (builtins.tryEval (builtins.deepSeq box.config.denbox.tailscale.serve box.drvPath)).success;
in
assert !(off.config.denbox.services ? tailscale);
assert off.host.devices == [ ] && off.host.capabilities == [ ] && off.host.secrets == { };
assert on.host.devices == [ "/dev/net/tun" ] && on.host.capabilities == [ "NET_ADMIN" ];
assert userspace.host.devices == [ ] && userspace.host.capabilities == [ ];
assert lib.all (box: box.host.secrets.tailscale_authkey.target == "/run/secrets/denbox_tailscale_authkey"
  && box.host.secrets.tailscale_authkey.allowEmpty) [ on userspace ];
assert on.config.denbox.tailscale.hostname == "on";
assert on.config.denbox.name == "on";
# The shapes the module refuses: a target without a scheme, a path without
# a leading /, a port that is not one, a key it does not know, two entries
# in one place, a port as both HTTP and HTTPS.
assert !evaluates { a = { to = "127.0.0.1:3773"; port = 443; }; };
assert !evaluates { a = { to = "http://127.0.0.1:1"; port = 443; path = "api"; }; };
assert !evaluates { a = { to = "http://127.0.0.1:1"; port = 70000; }; };
assert !evaluates { a = { to = "http://127.0.0.1:1"; port = 443; host = "x"; }; };
assert !evaluates { a = { to = "http://127.0.0.1:1"; port = 443; }; b = { to = "http://127.0.0.1:2"; port = 443; }; };
assert !evaluates { a = { to = "http://127.0.0.1:1"; port = 80; }; b = { to = "http://127.0.0.1:2"; port = 80; path = "/b"; https = false; }; };
assert evaluates { a = { to = "http://127.0.0.1:1"; port = 80; https = false; }; b = { to = "http://127.0.0.1:2"; port = 80; path = "/b"; https = false; }; };
runCommand "denbox-tailscale-check" { } ''
  fail() { echo "$*" >&2; exit 1; }
  has() { grep -qxF -e "$2" "$1" || fail "$1 lacks the line: $2"; }

  [[ ! -e ${off}/home-path/bin/tailscale && ! -e ${off}/home-files/.config/denbox/services/tailscale ]] \
    || fail "off: tailscale present"

  # On: the service, the command on PATH and the settings, in full.
  [[ $(readlink ${on}/home-files/.config/denbox/services/tailscale/run) == ${run on} ]] || fail "on: wrong run link"
  grep -qF -- '--socket=/run/denbox/tailscale/tailscaled.sock "$@"' ${on}/home-path/bin/tailscale || fail "on: no command"
  grep -qF -- 'exec ${tailscale}/bin/tailscaled --statedir="$state" --socket=/run/denbox/tailscale/tailscaled.sock' ${run on} \
    || fail "on: tailscaled not started with its state and socket"
  grep -q '/dev/net/tun' ${run on} || fail "on: no check for the tunnel"
  has ${configure on} "flags=(--reset '--hostname=on' '--advertise-tags=tag:denbox,tag:dev' '--ssh=true' '--accept-dns=false' '--login-server=https://headscale.example.com')"
  has ${configure on} 'key=/run/secrets/denbox_tailscale_authkey'
  # The served set is replaced, then each entry is served in name order.
  [[ $(grep -E '^(tailscale serve reset|serve )' ${configure on}) == "tailscale serve reset
serve '--http=8443' '--set-path=/api' http://127.0.0.1:48099
serve '--https=443' '--set-path=/' http://127.0.0.1:3773" ]] || fail "on: unexpected serving: $(grep serve ${configure on})"

  # Userspace: no tunnel and its proxies on loopback.
  ! grep -q '/dev/net/tun' ${run userspace} || fail "userspace: checks for the tunnel"
  grep -qF -- "--statedir=\"\$state\" --socket=/run/denbox/tailscale/tailscaled.sock '--tun=userspace-networking' '--socks5-server=127.0.0.1:1055' '--outbound-http-proxy-listen=127.0.0.1:1055'" ${run userspace} \
    || fail "userspace: unexpected tailscaled flags"
  has ${configure userspace} "flags=(--reset '--hostname=named' '--advertise-tags=' '--ssh=false' '--accept-dns=true')"
  [[ $(grep -cE '^serve ' ${configure userspace}) == 0 ]] || fail "userspace: serves"
  touch "$out"
''
