# Denbox design

A box is a Linux workspace built from a flake: a container on a Docker host
today, a VPS or an Incus instance later. One box can hold coding agents and
T3 Code, another only command-line tools. Both are the same mechanism with
different options switched on.

This file fixes the contracts between the parts. Change a contract here first,
then in code.

## Layers

| Layer | Where | Holds | Changes |
| --- | --- | --- | --- |
| Image | `image/`, public on ghcr.io | Debian, Nix, git, tini, a seed copy of the runtime | when Nix or the base moves |
| Kit | `kit/`, a flake input of every environment | Home Manager modules, packages, `denbox-api`, the runtime | often |
| Environment | its own repository, public or private | which boxes exist, which options each sets, its own modules | when its owner wants |

The image carries no application and no topology. Everything a box runs comes
from Nix, so a change to the kit never needs an image build.

## Environment contract

An environment is a flake with denbox as an input. It exposes one attribute
per box and system:

    legacyPackages.<system>.boxes.<name>

`nix build <flake>#boxes.<name>` resolves it for the current system, so no
configuration names an architecture.

```nix
{
  inputs.denbox.url = "github:riprsa/denbox";
  outputs = { denbox, ... }: {
    legacyPackages = denbox.lib.mkBoxes {
      personal = {
        imports = [ ./personal.nix ];
        denbox.t3.enable = true;
        denbox.agents.claude.enable = true;
        home.file.".claude/CLAUDE.md".source = ./agent/AGENTS.md;
      };
      tools = { };   # no agents: shell, tools, the API
    };
  };
}
```

`denbox.lib.mkBoxes` takes an attribute set of Home Manager modules and
returns `{ <system>.boxes.<name> = <box>; }` for `x86_64-linux` and
`aarch64-linux`. A box is the Home Manager activation package of that module
on top of the kit's modules:

- `<box>/activate` activates it.
- `<box>.follow` is the value of `denbox.follow` (see Sync).
- `<box>.host` is the value of `denbox.host`, what the box asks of its host
  (see What a box asks of its host).
- `<box>.config` is the evaluated configuration, for checks and debugging.

Nix looks every attribute up under `legacyPackages.<system>` before the top
level. A flake with other outputs that must evaluate without the kit builds
that level itself and calls `mkBoxes` only for `boxes`:

```nix
legacyPackages = nixpkgs.lib.genAttrs systems (system: {
  boxes = (denbox.lib.mkBoxes { personal = ./personal.nix; }).${system}.boxes;
});
```

`mkBoxes` defaults the user to `root` with home `/root` and
`home.stateVersion` to `26.05`; the box's module overrides any of them. It
allows the one unfree package the kit ships, Claude Code, and no other. The
kit pins nixpkgs and Home Manager; an environment may make them follow its
own.

## Options

Every option lives under `denbox.`. Nothing is on unless the table says so.

| Option | Default | Meaning |
| --- | --- | --- |
| `denbox.tools.enable` | `true` | fish, starship, fzf, zoxide, git, gh, glab, ripgrep, fd, jq, curl, ssh, tmux, neovim |
| `denbox.services.<name>` | `{ }` | path of an executable; the runtime supervises it |
| `denbox.optionalServices` | `[ ]` | names of services that stay off until switched on |
| `denbox.api.enable` | `true` | run `denbox-api` |
| `denbox.api.address` | `127.0.0.1:48099` | where it listens |
| `denbox.api.interface` | `eth0` | interface whose traffic the panel shows |
| `denbox.t3.enable` | `false` | T3 Code as a service |
| `denbox.t3.package` | kit's pin | override to patch or repin |
| `denbox.t3.port`, `.host`, `.projects`, `.settings` | `3773`, `0.0.0.0`, `~/Projects`, `{ }` | `.settings` is merged into T3's `settings.json` on start |
| `denbox.agents.claude.enable`, `.package` | `false`, kit's pin | Claude Code |
| `denbox.agents.claude.mcpServers` | `{ }` | merged into `mcpServers` of `~/.claude.json` on activation |
| `denbox.agents.codex.enable`, `.package` | `false`, kit's pin | Codex |
| `denbox.agents.codex.config` | `{ }` | Codex configuration, passed as one `-c` override per leaf value |
| `denbox.secrets.provider` | passthrough | see Secrets |
| `denbox.follow` | `{ }` | flake input name to a flake reference that names its host, not a registry name (see Sync) |
| `denbox.name` | the box's attribute name | set by `mkBoxes`; the box's name wherever one is needed |
| `denbox.tailscale.enable` | `false` | make the box a node of a tailnet (see Tailscale) |
| `denbox.tailscale.hostname` | `denbox.name` | the node's name in the tailnet |
| `denbox.tailscale.loginServer` | `null` | another control server than Tailscale's, as a URL |
| `denbox.tailscale.tags` | `[ ]` | tags the node asks for, such as `tag:denbox` |
| `denbox.tailscale.ssh` | `false` | accept Tailscale SSH into the box |
| `denbox.tailscale.acceptDns` | `true` | let the tailnet configure the box's resolver |
| `denbox.tailscale.userspace` | `false` | run without a tunnel device, for a host that grants none; the proxy listens on `127.0.0.1:1055` |
| `denbox.tailscale.serve.<name>` | `{ }` | a port of the box published to the tailnet: `port`, `https` (default `true`), `path` (default `/`), `to` |
| `denbox.host.ports.<name>` | T3's and the API's, see below | `{ port, hostPort ? port, address ? "127.0.0.1" }`, published on the host |
| `denbox.host.memory`, `.cpus`, `.pids` | `4g`, `2`, `2048` | limits of the container |
| `denbox.host.tmpSize`, `.shmSize` | `null`, `64m` | size of the tmpfs on `/tmp` (`null`: up to the memory limit) and of `/dev/shm` |
| `denbox.host.devices` | `[ ]` | host devices passed in, such as `/dev/net/tun` |
| `denbox.host.capabilities` | `[ ]` | capabilities added, without `CAP_`, such as `NET_ADMIN` |
| `denbox.host.binds` | `[ ]` | `{ source, target, readOnly ? true }`, host paths bound in |
| `denbox.host.dns` | `[ ]` | resolvers, IPv4; empty for the host's |

The kit installs an agent, starts it through the secrets provider and merges
configuration into the files the agent owns. It does not model an agent's
configuration: both options above are free-form and take whatever keys that
agent understands. Merging is per key, never per table, so a key the kit sets
leaves its neighbours alone, and so does a key the user sets by hand.
Codex splits a `-c` path at every dot and takes each part literally, so the
keys of `denbox.agents.codex.config` are passed unquoted, and a key with `.`
or `=` is refused.
Instructions, skills and other files an agent reads are the environment's own
`home.file` entries; the kit writes none of them.

An agent that needs a proxy, a wrapper or another build overrides its
`.package`. Every module receives the argument `kit`, the kit's packages for
the box's system (`kit.claude`, `kit.codex`, `kit.t3`, ...), to wrap or patch.
The kit knows nothing about a particular proxy, vault or cluster.

## Layout in a box

| Path | Holds |
| --- | --- |
| `~/.config/denbox/services/NAME/run` | a supervised service, optionally with `finish` |
| `~/.config/denbox/shell` | the executable `denbox shell` runs, written by the tools module; bash without it |
| `~/.local/state/denbox/` | runtime state: fetched sources, the applied revision, `status` |
| `~/.local/state/denbox/optional-services/NAME` | marker of a switched-on optional service |
| `~/.local/state/denbox/logs/NAME/current` | a service's log, 10 x 1 MB |
| `/run/denbox/` | s6 scan directory (`services/`) and locks; gone on restart, and may be `noexec` |
| `/run/secrets/denbox_bootstrap`, `/run/secrets/denbox_git_token` | the bootstrap, mounted by the host |
| `/run/secrets/denbox_tailscale_authkey` | the key a box joins its tailnet with, when the host gives one |
| `~/.local/state/denbox/tailscale/` | the node's identity in the tailnet; it survives restarts with the home |

One command, `denbox`, replaces the set of commands the predecessor had:

    denbox supervise                      PID 1 after tini: s6 over the services and the sync loop; refused while one runs
    denbox sync [--once]                  fetch, build, activate, reconcile services
    denbox service status [NAME]
    denbox service start|stop|restart NAME
    denbox service reconcile              make the supervised services match ~/.config/denbox/services now
    denbox service logs NAME [-f] [-n N]
    denbox shell [ARGS]                   the configured shell, with the secrets of consumer `shell`

The sync loop is the supervised service `denbox-sync`; a box cannot name a
service so. `~/.config/denbox/shell` is responsible for calling the secrets
provider with consumer `shell`; `denbox shell` only runs it.

The predecessor's command, variable and directory names do not appear
anywhere in this repository. There is no compatibility layer for them.

## Bootstrap

The host hands a box two files. Nothing else tells it what to become.

`denbox_bootstrap` (JSON):

```json
{
  "version": 2,
  "repository": "https://github.com/me/environment.git",
  "ref": "main",
  "box": "personal",
  "sync_interval": 300,
  "apply_timeout": 1800,
  "git_username": "oauth2"
}
```

`ref` is a branch. `sync_interval` (30 to 86400, default 300), `apply_timeout`
(30 to 86400, default 1800) and `git_username` (default `oauth2`) may be left
out. A bootstrap that is missing or not valid leaves the last valid one in use.

`denbox_git_token` holds a token that can read the repository, or is empty for
a public one. 1Password is not part of the bootstrap.

## Sync

`denbox sync` runs every `sync_interval` seconds:

1. Fetch `ref` of `repository` with the token, without the user's Git
   configuration, and unpack that revision into a snapshot without `.git`.
2. Read `boxes.<box>.follow` from the snapshot.
3. Build `path:<snapshot>#boxes.<box>`, with `--override-input NAME REF` for
   every entry of `follow`, `REF` pinned to the revision it resolved to.
4. Run `<box>/activate`, then reconcile the supervised services with
   `~/.config/denbox/services`.

A failed fetch, build or activation keeps the box as it was. A box restarts
from its last applied state without network.

Steps 3 and 4 are skipped while nothing changed: the revision of the
environment is the one applied and every followed reference still resolves to
the revision it had then. Resolving a reference asks its host for the current
revision and evaluates nothing, and `follow` is read again only for a new
revision, so an idle box costs a fetch per sync. A skipped sync still
reconciles. A reference that cannot be resolved fails the sync and keeps the
box as it was. After an activation, at most once a day, the runtime keeps three
generations of the user's profiles and collects the store.

`denbox.follow` is how a kit update reaches boxes without a commit to every
environment. `denbox.follow.denbox = "github:riprsa/denbox";` makes the box
build against the kit's current `main` at every sync, whatever the
environment's `flake.lock` says. Without it the lock decides, and a kit update
arrives when the environment updates its lock. The default is empty.

Following is for a kit that has settled. It gives up the one step where a
person looks at a kit change before a particular box takes it; see Trust.

The runtime is part of the box it builds: activation installs it as
`~/.nix-profile/bin/denbox`. The image starts that one when it exists and its
own seed copy otherwise, so a box needs the image's copy only for its first
build. When a sync changes the runtime's store path, the sync loop exits and
s6 starts the new one.

## Binary cache

Most of a box comes prebuilt from `cache.nixos.org`. The kit's own packages
come from the public cache `https://denbox.cachix.org`, key
`denbox.cachix.org-1:0wTpaHGYAg3yirdzhxYjNPnzPjVjBiNoMHaK4Hptx9I=`, so a box
does not fetch a Go toolchain to compile `denbox-api`.

- **What is in it**: `denbox-api` and the runtime for `x86_64-linux`, with
  their runtime closures, pushed by CI after the checks pass on `main`. A box
  hits it when it builds against the kit's nixpkgs; a box whose environment
  makes nixpkgs follow its own builds them itself.
- **What never is**: T3 Code, Codex and Claude Code, or any other vendor
  binary. Every box fetches those from their vendors.
- **How a box uses it**: the runtime adds the cache with
  `--extra-substituters` and `--extra-trusted-public-keys` to the evaluation
  and the build of a sync, the first build on the image's seed included,
  after whatever the host configures. An unreachable cache is a warning and
  the box builds without it; a network that drops the connection silently costs
  `connect-timeout` times `download-attempts` once per build (80 seconds with
  Nix's defaults), inside `apply_timeout`.
- **A Nix daemon** ignores substituters and keys from a user it does not
  trust. root and single-user Nix are trusted; for an ordinary user the
  daemon's `nix.conf` needs

      extra-trusted-substituters = https://denbox.cachix.org
      extra-trusted-public-keys = denbox.cachix.org-1:0wTpaHGYAg3yirdzhxYjNPnzPjVjBiNoMHaK4Hptx9I=

  The first line lets the runtime add the cache; it does not make other Nix
  users use it.
- **Off**: `DENBOX_BINARY_CACHE=0` in the runtime's environment leaves it out.

## Secrets

The kit never reads a vault. `denbox.secrets.provider` is an executable called
as

    PROVIDER CONSUMER -- COMMAND [ARGS...]

It must exec `COMMAND` with the environment variables meant for `CONSUMER`.
The kit's services call it with these consumers: `shell` for interactive
shells, `agents` for Claude and Codex, `t3` for T3 Code. The default provider
adds nothing and execs the command. An environment points the option at its
own program (a secrets broker, sops, a file reader).

## Tailscale

By default a box has no place in a network of its own: it is reached through
ports its host publishes, and what it sends leaves as its host. With
`denbox.tailscale.enable` the box is a node of a tailnet instead, a machine of
its own with a name, an address and its own entry in the tailnet's access
rules.

- The kit runs `tailscaled` as the supervised service `tailscale` and puts a
  `tailscale` command on PATH that talks to it, through the socket
  `/run/denbox/tailscale/tailscaled.sock`. The node's state is in
  `~/.local/state/denbox/tailscale/`, so a box keeps its identity across
  restarts and image changes.
- **Settings.** Every start of the service applies `hostname`,
  `loginServer`, `tags`, `ssh` and `acceptDns` with `tailscale up --reset`,
  so a setting changed by hand with `tailscale set` lasts until the next
  start. A sync that changes an option restarts the service.
- **Joining.** A box that is not logged in joins with the key in
  `/run/secrets/denbox_tailscale_authkey`. The key comes from the host and
  not through the secrets provider, because a provider may itself be reachable
  only inside the tailnet. It is needed once; without it the service waits and
  `tailscale login` in the box prints a URL to log in by hand (with
  `--login-server` for another control server; the service's log names the
  command). Whether a node
  is short-lived is a property of the key (an ephemeral key removes the node
  when the box is gone), not of the box.
- **The tunnel.** By default the box has a tunnel device, so every program in
  it reaches the tailnet without knowing, and what it sends arrives as the
  box. The host has to grant that: `deploy/compose.tailscale.yaml` adds
  `/dev/net/tun`, the `NET_ADMIN` capability and the key's secret. On a host
  that grants neither, `denbox.tailscale.userspace` runs the node without a
  device: the tailnet still reaches the box, and programs in the box reach
  the tailnet only through the proxy `tailscaled` then offers, SOCKS5 and
  HTTP on `127.0.0.1:1055`. A box without the device or the capability and
  without `userspace` does not fall back: its service says why and stays down.
- **Serving.** `denbox.tailscale.serve.<name> = { port = 443; https = true;
  path = "/"; to = "http://127.0.0.1:3773"; }` publishes a local port to the
  tailnet with `tailscale serve`, under the node's name and, with `https`,
  the tailnet's certificate. Nothing is served unless the box says so: each
  start replaces what the node serves with these entries. A served port
  needs no port published by the host.
- **Another control server.** `denbox.tailscale.loginServer` points the node
  at a self-hosted control server. A box is a node of one tailnet.

## denbox-api

A small Go server inside the box, reached only through the box's private front
door. It serves data and takes commands about the box. It never serves code.
Every request must carry the header `x-denbox-api: 1`; a web page cannot send
it cross-origin without a preflight the server never answers. The header stops
other pages from calling the API; it does not authenticate anyone.

| Route | Does |
| --- | --- |
| `GET /state` | `{ system, services, ports }`; a failing section is `{"state":"unavailable","reason":"..."}` |
| `POST /services/restart` | `{ "name": "..." }` |
| `POST /services/toggle` | `{ "name": "...", "on": true }`, optional services only |

It talks to the supervisor only through `denbox service ...`.

## Trust

A box is not trusted by anything outside it. Its agents run as root, act
without asking and read text from the web, so whatever a box serves may have
been written by someone else. Two rules follow.

- **Nothing outside a box runs code a box hands it.** The browser extension
  shows a box's data and sends it commands; the code it runs comes from Git.
- **Code reaches a box or a browser only through a merge.** A box builds what
  is on a branch of the environment (and of the kit, when it follows it). The
  extension runs bundles from a branch of a repository. That is a gate only
  while the branch is protected and no credential inside a box can push to it
  or merge into it. Give agents an account of their own, without that right.
- **A box in a tailnet is still a box.** Without Tailscale of its own it
  shares its host's place in the network and reaches whatever the host
  reaches. As a node it can be given a tag and exactly the access a box
  should have. Do that: joining a tailnet without rules for the box only
  moves the problem.

## Browser

`extension/` is a browser extension with its own manifest key. It holds a
loader, an options page, the panel and the permissions features need. Its
options hold two separate things:

- **The box address**: where `denbox-api` answers. The panel, a page of the
  extension itself, shows that box's state, services and ports from `/state`
  and sends restarts and toggles. What the box returns is data: the panel puts
  it into the page as text, never as markup or code.
- **Sources**: a list of URLs, each with an optional token, each returning one
  bundle. A source is a file in a Git repository on a protected branch, for
  example a raw file URL of the environment's `main`. The loader fetches every
  source every 5 minutes and runs what they hold. It accepts a source only
  on a short list of Git hosts kept in its code, and refuses one that
  redirects off that list. The list says what is allowed, not what is
  refused: a box answers to many names, and none of them is a Git host.

A bundle is

```json
{ "version": 1, "parts": { "<name>": { "background": "...", "content": [ { "matches": ["..."], "js": "..." } ], "pages": { "<page>": { "html": "...", "js": "..." } } } } }
```

Each part starts on its own; one that throws does not stop the others. A
source that fails to load or parse leaves its previous bundle running. A part
name is unique across sources; a second part of the same name is reported and
not started. A part without `background` leaves the key out; `content` and
`pages` may be empty. A part's code gets the box address and a helper that
calls the box's API, and treats the answers as data.

`denbox.lib.mkBundle pkgs { <name> = { background, content, pages }; }` builds
a bundle from files, the same shape with paths in place of text. A repository
that is a source commits the built file, and its CI fails when the file is not
what its parts build.

## What a box asks of its host

The environment describes the box completely, and that includes what its
container needs from the machine that runs it. `denbox.host` holds it; the
kit's defaults are what the standard deployment gives, and a module that
knows a requirement declares it itself: T3 Code's port as `ports.t3` when
`denbox.t3.enable` and T3 listens beyond loopback, the API's as `ports.api`
when `denbox.api.address` does. An environment moves such a port with
`denbox.host.ports.t3.hostPort = 13773;` and adds its own:

```nix
denbox.host = {
  shmSize = "2g";                     # a browser
  devices = [ "/dev/net/tun" ];       # a tunnel
  capabilities = [ "NET_ADMIN" ];
  ports.web = { port = 8080; address = "0.0.0.0"; };
  binds = [{ source = "/srv/data"; target = "/data"; }];
};
```

Every value is typed narrowly enough that whatever evaluates can be written
into a Compose file or a systemd unit without quoting: paths and sizes of a
few characters, IPv4 addresses, capability names. A wrong value, or a host
port published twice, fails the evaluation with the option's name.

`nix eval --json <flake>#boxes.<name>.host` prints the declaration, and
`deploy/render` turns it into a deployment, adding what only the host knows:
the box's name, the image and where the bootstrap and token files are.

    deploy/render --format compose --name NAME --image IMAGE --bootstrap FILE --token FILE HOST.json
    deploy/render --format quadlet --name NAME --image IMAGE --bootstrap FILE --token FILE --output DIR HOST.json
    deploy/render --explain --name NAME HOST.json

`compose` prints one Compose file; for a box that asks for nothing special it
is the same deployment as `deploy/compose.yaml`. `quadlet` writes the Podman
Quadlet units `denbox-NAME.container`, `denbox-NAME-home.volume` and
`denbox-NAME-nix.volume`. Relative file paths are relative to the Compose
project directory, or to the directory of the units. `--explain` prints what
the box asks for in words, with what weakens its isolation from the host
first, each marked `!`: capabilities, devices, host paths, ports bound beyond
loopback. The script refuses, with status 65, a declaration it cannot express
exactly, a key it does not know included; it never drops one. It needs bash
and jq.

A change to an environment's repository must not quietly hand a container
more of the host. A host that deploys from the declaration shows the
explanation before it starts a box, and again whenever it differs from the
one accepted last, and starts the box only when a person agrees.

## Hosts

A box needs Linux, Nix and something that runs `denbox supervise` at start.

- **Docker**, the first host. `image/` builds the image; `deploy/compose.yaml`
  is the standard deployment (home and Nix volumes, the two bootstrap
  secrets, loopback ports). `deploy/compose.tailscale.yaml` is the overlay for
  a box that joins a tailnet. An environment can add Compose overlays from
  its repository; `deploy/render --format compose` writes the deployment from
  the box's `denbox.host` instead.
- **Podman**, rootless or not: the same image, deployed as Quadlet units
  from `deploy/render --format quadlet` and started as a systemd service,
  `systemctl --user start denbox-NAME` for a user's. Rootless Podman sets a
  memory, CPU or process limit only through a cgroup controller that systemd
  delegates to the user; most distributions delegate memory and pids, and
  cpu needs `Delegate=` in a drop-in for `user@.service`. On SELinux, the
  bootstrap files are relabeled for the container; a bound host path is not.
- **Baked image**, for short-lived boxes: the same image with one box already
  built into its store, made by the environment's CI. It starts without a
  build and without volumes.
- **VPS and Incus**, later: a NixOS module that runs `denbox supervise` as a
  unit.

`install.sh` asks for the environment repository, the box name and, for a
private repository, a token. It pulls the public image and starts Compose.
With `--tailscale` it adds the overlay and asks for the key.

## Repository

```
flake.nix, flake.lock     lib.mkBoxes, lib.mkBundle, homeManagerModules.default, packages, checks, templates.default
kit/go.mod, api/, cmd/    denbox-api
kit/nix/modules/          one file per option group
kit/nix/packages/         pins and builds: denbox-api, the browser bundle, t3, claude, codex, runtime
kit/nix/checks/           flake checks beyond the package builds
kit/runtime/              the denbox command
extension/                the browser extension, the panel included
image/                    Dockerfile, the denbox launcher, root's login shell
deploy/, install.sh       standard Compose deployment, deploy/render, installer
template/                 what `nix flake init -t github:riprsa/denbox` writes
docs/                     this file
```
