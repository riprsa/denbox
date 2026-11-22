# What a box asks of the machine that runs its container: published ports,
# limits, the size of /tmp and /dev/shm, devices, capabilities, host paths,
# a resolver and files the host provides as secrets. mkBoxes exposes the value as `<box>.host`, and
# deploy/render turns it into a Compose file or Podman Quadlet units
# (docs/design.md, What a box asks of its host). The defaults are those of
# the standard deployment. A module that knows a requirement declares it
# here itself, as t3.nix and api.nix do for their ports.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.denbox.host;
  # The patterns deploy/render checks, so that a value it would refuse fails
  # evaluation instead: no characters that Compose, Podman or systemd read
  # as syntax. The description is what an error names.
  matching = description: pattern: types.strMatching pattern // { inherit description; };
  path = matching "absolute path of letters, digits and ._/@+-" "/[A-Za-z0-9._/@+-]*";
  size = matching "size with a unit k, m or g, such as 4g" "[1-9][0-9]*[kmg]";
  ipv4 = matching "IPv4 address, such as 127.0.0.1"
    "((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])";
  device = matching "path under /dev, such as /dev/net/tun" "/dev/[A-Za-z0-9._/@+-]+";
  capability = types.addCheck (matching "capability without the CAP_ prefix, such as NET_ADMIN" "[A-Z][A-Z0-9_]*")
    (c: !lib.hasPrefix "CAP_" c);
  portNumber = types.ints.between 1 65535;
  # Paths the deployment mounts itself; neither a bind nor a secret may take one.
  reserved = [ "/root" "/nix" "/tmp" "/dev/shm" "/run/denbox" "/run/secrets"
    "/run/secrets/denbox_bootstrap" "/run/secrets/denbox_git_token" ];

  # A port of the box published on the host.
  port = types.submodule ({ config, ... }: {
    options = {
      port = mkOption {
        type = portNumber;
        description = "Port the box listens on.";
      };
      hostPort = mkOption {
        type = portNumber;
        default = config.port;
        defaultText = lib.literalExpression "port";
        description = "Port on the host.";
      };
      address = mkOption {
        type = ipv4;
        default = "127.0.0.1";
        description = "Host address the port is bound to; anything but loopback reaches the network.";
      };
    };
  });

  # A host path bound into the box.
  bind = types.submodule {
    options = {
      source = mkOption {
        type = path;
        description = "Path on the host.";
      };
      target = mkOption {
        type = path;
        description = "Path in the box.";
      };
      readOnly = mkOption {
        type = types.bool;
        default = true;
        description = "Whether the box can only read it.";
      };
    };
  };

  # A file the host provides, such as a key: the installer asks a person
  # for it and stores it; deploy/render mounts it read-only.
  secret = types.submodule ({ name, ... }: {
    options = {
      target = mkOption {
        type = path;
        default = "/run/secrets/denbox_${name}";
        defaultText = lib.literalExpression ''"/run/secrets/denbox_''${name}"'';
        description = "Where the file appears in the box.";
      };
      allowEmpty = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the host may give an empty file, for a secret the box can do without.";
      };
      description = mkOption {
        type = matching "one line of printable ASCII, at most 200 characters" "[ -~]{1,200}";
        example = "Tailscale auth key the box joins its tailnet with";
        description = "What the secret is, in one line for the person asked for it.";
      };
    };
  });
  secretName = name: builtins.match "[a-z][a-z0-9_]*" name != null && !lib.elem name [ "bootstrap" "git_token" ];
  targets = map (s: s.target) (lib.attrValues cfg.secrets) ++ map (b: b.target) cfg.binds;
in
{
  options.denbox.host = {
    # By name, so that an environment can move a port a module declared:
    # denbox.host.ports.t3.hostPort = 13773;
    ports = mkOption {
      type = types.attrsOf port;
      default = { };
      example = { web = { port = 8080; address = "0.0.0.0"; }; };
      description = "Ports of the box published on the host, by name.";
    };

    # Limits of the container.
    memory = mkOption {
      type = size;
      default = "4g";
      description = "Memory limit, with a unit: k, m or g.";
    };
    cpus = mkOption {
      type = types.numbers.positive;
      default = 2;
      description = "CPU limit, in CPUs; may be a fraction.";
    };
    pids = mkOption {
      type = types.ints.positive;
      default = 2048;
      description = "Process limit.";
    };
    tmpSize = mkOption {
      type = types.nullOr size;
      default = null;
      description = "Size of the tmpfs on /tmp; null for no limit but the memory limit.";
    };
    shmSize = mkOption {
      type = size;
      default = "64m";
      description = "Size of /dev/shm; a browser wants more than the default.";
    };

    # What weakens the isolation from the host. A host shows these before it
    # starts a box and asks.
    devices = mkOption {
      type = types.listOf device;
      default = [ ];
      example = [ "/dev/net/tun" ];
      description = "Host devices passed in, at the same path.";
    };
    capabilities = mkOption {
      type = types.listOf capability;
      default = [ ];
      example = [ "NET_ADMIN" ];
      description = "Capabilities added to the container's default set, without the CAP_ prefix.";
    };
    binds = mkOption {
      type = types.listOf bind;
      default = [ ];
      example = [{ source = "/srv/data"; target = "/data"; }];
      description = "Host paths bound into the box, read-only unless they say otherwise.";
    };

    # By name, the name in lowercase letters, digits and _, as the installer
    # asks for it: --secret-file NAME=FILE or DENBOX_SECRET_<NAME>.
    secrets = mkOption {
      type = types.attrsOf secret;
      default = { };
      example = { api_key = { description = "Key of the example API"; }; };
      description = "Files the host provides as secrets, by name.";
    };

    dns = mkOption {
      type = types.listOf ipv4;
      default = [ ];
      example = [ "1.1.1.1" ];
      description = "Resolvers of the box; empty for the host's.";
    };
  };

  # Two ports on one host port collide when they share an address or one
  # of them takes every address. Secrets have names the installer can ask
  # for and places of their own.
  config.assertions = [
    {
      assertion = lib.all secretName (lib.attrNames cfg.secrets);
      message = "denbox.host.secrets: a name is lowercase letters, digits and _, starts with a letter, and is not bootstrap or git_token: ${toString (lib.attrNames cfg.secrets)}";
    }
    {
      assertion = lib.allUnique targets && !lib.any (t: lib.elem t reserved) targets;
      message = "denbox.host: two secrets or binds share a target, or one takes a path the deployment mounts: ${toString targets}";
    }
  ] ++ lib.mapAttrsToList (hostPort: ports: {
    assertion = lib.length ports == 1
      || (!lib.elem "0.0.0.0" (map (p: p.address) ports) && lib.allUnique (map (p: p.address) ports));
    message = "denbox.host.ports: host port ${hostPort} is published twice (${lib.concatMapStringsSep ", " (p: p.name) ports})";
  }) (lib.groupBy (p: toString p.hostPort) (lib.mapAttrsToList (name: p: p // { inherit name; }) cfg.ports));
}
