# Tailscale: the box as a node of a tailnet (docs/design.md, Tailscale).
# tailscaled runs as the supervised service tailscale; the `tailscale`
# command on PATH talks to its socket. On every start the service joins with
# the host's key when the node is logged out, applies the settings below and
# makes what the node serves equal denbox.tailscale.serve.
{ config, lib, pkgs, ... }:
let
  cfg = config.denbox.tailscale;
  inherit (lib) mkOption types;
  socket = "/run/denbox/tailscale/tailscaled.sock";
  keyFile = "/run/secrets/denbox_tailscale_authkey";
  # Both proxies of a userspace node, on one port.
  proxy = "127.0.0.1:1055";

  cli = pkgs.writeShellScriptBin "tailscale" ''
    exec ${pkgs.tailscale}/bin/tailscale --socket=${socket} "$@"
  '';

  # A type with the description an error about a definition shows.
  matching = pattern: description: types.strMatching pattern // { inherit description; };

  # One entry of denbox.tailscale.serve: what `tailscale serve` publishes.
  serveEntry = types.submodule {
    options = {
      port = mkOption {
        type = types.port;
        example = 443;
        description = "Port of the node the entry is served on.";
      };
      https = mkOption {
        type = types.bool;
        default = true;
        description = "HTTPS with the tailnet's certificate; plain HTTP when false.";
      };
      path = mkOption {
        type = matching "^/[^[:space:]]*$" "URL path starting with /";
        default = "/";
        description = "Path under which the local server is served.";
      };
      to = mkOption {
        type = matching "^(http|https|https\\+insecure)://[^[:space:]/]+(/[^[:space:]]*)?$"
          "URL of a local server: http://, https:// or https+insecure://HOST:PORT[/PATH]";
        example = "http://127.0.0.1:3773";
        description = "The local server the entry forwards to.";
      };
    };
  };

  # The settings, given to `tailscale up` in full: --reset makes every
  # setting not named here its default, so the node is what the options say.
  upFlags = [
    "--reset"
    "--hostname=${cfg.hostname}"
    "--advertise-tags=${lib.concatStringsSep "," cfg.tags}"
    "--ssh=${lib.boolToString cfg.ssh}"
    "--accept-dns=${lib.boolToString cfg.acceptDns}"
  ] ++ lib.optional (cfg.loginServer != null) "--login-server=${cfg.loginServer}";

  # One `serve` line per entry, in the order of their names.
  serveLines = lib.mapAttrsToList (_: entry: "serve " + lib.escapeShellArgs [
    "--${if entry.https then "https" else "http"}=${toString entry.port}"
    "--set-path=${entry.path}"
    entry.to
  ]) cfg.serve;

  # configure PID: runs next to tailscaled, whose PID it is given, and ends
  # with it. Joins or applies the settings, waits until the node is up, then
  # replaces what the node serves. The key goes to tailscale as a path.
  configure = pkgs.writeShellScript "denbox-tailscale-configure" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.jq ]}:$PATH
    pid=$1
    key=${keyFile}
    flags=(${lib.escapeShellArgs upFlags})
    tailscale() { ${lib.getExe cli} "$@"; }
    backend() { tailscale status --json 2> /dev/null | jq -r '.BackendState // ""'; }
    pause() { kill -0 "$pid" 2> /dev/null || exit 0; sleep "$1"; }
    serve() { tailscale serve --bg --yes "$@" || echo "denbox: could not serve $*"; }

    # NoState while tailscaled starts; NeedsLogin for a node without identity.
    for ((attempt = 0; attempt < 30; attempt++)); do
      state=$(backend)
      [[ $state == "" || $state == NoState ]] || break
      pause 1
    done
    applied=false
    if [[ $state == NeedsLogin ]]; then
      if [[ -s $key ]]; then
        echo "denbox: joining the tailnet with the key in $key"
        tailscale up "''${flags[@]}" --auth-key="file:$key" --timeout=120s && applied=true
      else
        echo "denbox: no key in $key; log in by hand with: tailscale login${
          lib.optionalString (cfg.loginServer != null) " --login-server=${cfg.loginServer}"}"
      fi
    else
      tailscale up "''${flags[@]}" --timeout=120s && applied=true
    fi
    until [[ $(backend) == Running ]]; do pause 5; done
    # A node logged in by hand gets its settings now.
    if [[ $applied == false ]]; then tailscale up "''${flags[@]}" --timeout=120s || true; fi
    tailscale serve reset
    ${lib.concatStringsSep "\n" serveLines}
    echo "denbox: the node is up and serves ${toString (lib.length serveLines)} entries"
  '';

  # The kernel tunnel needs the device and NET_ADMIN (bit 12 of CapEff).
  # Without them the service says why and stays down: falling back to a
  # userspace node would change what the box's programs can reach.
  checkTunnel = lib.optionalString (!cfg.userspace) ''
    capabilities=$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status)
    if [[ ! -c /dev/net/tun ]] || (( (16#''${capabilities:-0} >> 12 & 1) == 0 )); then
      echo "denbox: tailscale needs /dev/net/tun and the NET_ADMIN capability, which the box asks for in" \
        "denbox.host. Start it from a deployment rendered from that (install.sh does), or set" \
        "denbox.tailscale.userspace = true for a node without a tunnel."
      ${pkgs.s6}/bin/s6-svc -d .
      exit 1
    fi
  '';

  tunnelFlags = lib.optionals cfg.userspace [
    "--tun=userspace-networking"
    "--socks5-server=${proxy}"
    "--outbound-http-proxy-listen=${proxy}"
  ];

  service = pkgs.writeShellScript "denbox-tailscale-service" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnused ]}:$PATH
    state="$HOME/.local/state/denbox/tailscale"
    mkdir -p "$state" ${dirOf socket}
    chmod 0700 "$state"
    ${checkTunnel}
    ${configure} $$ &
    exec ${pkgs.tailscale}/bin/tailscaled --statedir="$state" --socket=${socket} ${lib.escapeShellArgs tunnelFlags}
  '';

  # Entries that would take the same place of the node, and ports given both
  # as HTTP and as HTTPS.
  places = lib.groupBy (entry: "${toString entry.port}${entry.path}") (lib.attrValues cfg.serve);
  schemes = lib.mapAttrs (_: entries: lib.unique (map (entry: entry.https) entries))
    (lib.groupBy (entry: toString entry.port) (lib.attrValues cfg.serve));
in
{
  options.denbox.tailscale = {
    enable = lib.mkEnableOption "the box as a node of a tailnet, with tailscaled as the service tailscale";
    hostname = mkOption {
      type = matching "^[A-Za-z0-9_-]+$" "host name (letters, digits, _ and -)";
      default = config.denbox.name;
      defaultText = lib.literalExpression "config.denbox.name";
      description = "The node's name in the tailnet.";
    };
    loginServer = mkOption {
      type = types.nullOr (matching "^https?://[^[:space:]]+$" "URL of a control server");
      default = null;
      example = "https://headscale.example.com";
      description = "Another control server than Tailscale's.";
    };
    tags = mkOption {
      type = types.listOf (matching "^tag:[A-Za-z0-9-]+$" "Tailscale tag such as tag:denbox");
      default = [ ];
      example = [ "tag:denbox" ];
      description = "Tags the node asks for; the tailnet's rules decide what a tag may reach.";
    };
    ssh = mkOption {
      type = types.bool;
      default = false;
      description = "Accept Tailscale SSH into the box.";
    };
    acceptDns = mkOption {
      type = types.bool;
      default = true;
      description = "Let the tailnet configure the box's resolver (/etc/resolv.conf).";
    };
    userspace = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run without a tunnel device, for a host that grants none. The tailnet
        still reaches the box; programs in the box reach the tailnet only
        through the SOCKS5 and HTTP proxy tailscaled offers on ${proxy}.
      '';
    };
    serve = mkOption {
      type = types.attrsOf serveEntry;
      default = { };
      example = { t3 = { port = 443; to = "http://127.0.0.1:3773"; }; };
      description = "Local servers published to the tailnet with `tailscale serve`; nothing else is served.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (entries: lib.length entries == 1) (lib.attrValues places);
        message = "denbox.tailscale.serve: two entries serve the same port and path.";
      }
      {
        assertion = lib.all (s: lib.length s == 1) (lib.attrValues schemes);
        message = "denbox.tailscale.serve: a port is served both as HTTP and as HTTPS.";
      }
    ];
    home.packages = [ cli ];
    denbox.services.tailscale = service;
    # What the host grants: the tunnel unless in userspace, and the key.
    denbox.host = {
      devices = lib.optional (!cfg.userspace) "/dev/net/tun";
      capabilities = lib.optional (!cfg.userspace) "NET_ADMIN";
      secrets.tailscale_authkey = {
        target = keyFile;
        allowEmpty = true;
        description = "Tailscale auth key the box joins its tailnet with, used once; empty to run tailscale login in the box";
      };
    };
  };
}
