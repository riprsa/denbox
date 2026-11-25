# Denbox design

A box is a Linux workspace built from a flake: a container on a Docker host,
or a user on a Linux machine with systemd. One box can hold coding agents and
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
| `denbox.apply` | `auto` | `approve`: a sync builds and waits for `denbox apply` instead of activating (see Sync) |
| `denbox.name` | the box's attribute name | set by `mkBoxes`; the box's name wherever one is needed |
| `denbox.tailscale.enable` | `false` | make the box a node of a tailnet (see Tailscale) |
| `denbox.tailscale.hostname` | `denbox.name` | the node's name in the tailnet |
| `denbox.tailscale.loginServer` | `null` | another control server than Tailscale's, as a URL |
| `denbox.tailscale.tags` | `[ ]` | tags the node asks for, such as `tag:denbox` |
| `denbox.tailscale.ssh` | `false` | accept Tailscale SSH into the box |
| `denbox.tailscale.acceptDns` | `true` | let the tailnet configure the box's resolver |
| `denbox.tailscale.netfilterMode` | `"on"` | tailscaled's firewall rules: `on`, `nodivert` or `off`; see Tailscale |
| `denbox.tailscale.userspace` | `false` | run without a tunnel device, for a host that grants none; the proxy listens on `127.0.0.1:1055` |
| `denbox.tailscale.serve.<name>` | `{ }` | a port of the box published to the tailnet: `port`, `https` (default `true`), `path` (default `/`), `to` |
| `denbox.host.ports.<name>` | T3's and the API's, see below | `{ port, hostPort ? port, address ? "127.0.0.1" }`, published on the host |
| `denbox.host.memory`, `.cpus`, `.pids` | `4g`, `2`, `2048` | limits of the container |
| `denbox.host.tmpSize`, `.shmSize` | `null`, `64m` | size of the tmpfs on `/tmp` (`null`: up to the memory limit) and of `/dev/shm` |
| `denbox.host.devices` | `[ ]` | host devices passed in, such as `/dev/net/tun` |
| `denbox.host.capabilities` | `[ ]` | capabilities added, without `CAP_`, such as `NET_ADMIN` |
| `denbox.host.binds` | `[ ]` | `{ source, target, readOnly ? true }`, host paths bound in |
| `denbox.host.dns` | `[ ]` | resolvers, IPv4; empty for the host's |
| `denbox.host.secrets.<name>` | `{ }` | `{ description, target ? "/run/secrets/denbox_<name>", allowEmpty ? false }`, a file the host provides |

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
| `~/.config/denbox/apply` | holds `approve` in a box whose `denbox.apply` asks for approval, absent otherwise; the runtime reads it from the applied box in the store, not from here |
| `~/.local/state/denbox/` | runtime state: fetched sources, the applied revision, `status` |
| `~/.local/state/denbox/pending.json` | the box that waits for approval (see Sync); absent when none does |
| `~/.local/state/denbox/optional-services/NAME` | marker of a switched-on optional service |
| `~/.local/state/denbox/logs/NAME/current` | a service's log, 10 x 1 MB |
| `/run/denbox/` | s6 scan directory (`services/`) and locks; gone on restart, and may be `noexec`. `/run/denbox-USER/` for a box whose user is not root |
| `/run/secrets/denbox_bootstrap`, `/run/secrets/denbox_git_token` | the bootstrap, mounted by the host; a machine passes other paths (see Hosts) |
| `/run/secrets/denbox_NAME` | a secret the box declares in `denbox.host.secrets.NAME`, by default |
| `/run/secrets/denbox_tailscale_authkey` | the key a box joins its tailnet with, the Tailscale module's secret `tailscale_authkey` |
| `~/.local/state/denbox/tailscale/` | the node's identity in the tailnet; it survives restarts with the home |

One command, `denbox`, replaces the set of commands the predecessor had:

    denbox supervise                      s6 over the services and the sync loop, under tini or systemd; refused while one runs
    denbox sync [--once]                  fetch, build, activate or leave pending, reconcile services
    denbox pending                        print the box that waits for approval, as JSON; nothing when none does
    denbox apply [REVISION]               activate the pending box; with REVISION, only that one
    denbox host                           print boxes.<box>.host of the bootstrap's environment, followed as a sync does; builds nothing
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

Before a build the runtime removes `/homeless-shelter`, the home Nix gives a
build. In a container Nix has no sandbox, so a build that writes to its home
creates that directory for real, and Nix refuses every later build while it
exists.

With `denbox.apply = "approve"` step 4 waits for a person. The sync builds as
before, activates nothing, and records the result in `pending.json`:

```json
{
  "revision": "9f2c...", "box": "personal", "subject": "Add ripgrep",
  "built": "2026-11-25T08:00:00Z", "store": "/nix/store/...-home-manager-generation",
  "applied": "41ab...", "apply": "approve",
  "changes": ["ripgrep: ∅ → 14.1.1, +5.9 MiB"],
  "follow": {}, "resolved": {}
}
```

`applied` is the revision the box runs, `changes` is what
`nix store diff-closures` says of the two boxes, and `apply` is the mode the
box would have once applied, so whoever approves sees a revision that
switches approval off. `denbox apply` activates the pending box and
reconciles; `denbox apply REVISION` refuses any other revision, so that an
approval never applies a commit that arrived after it was given. A newer
commit replaces the pending one, a branch that returns to the applied
revision leaves nothing pending, and a pending box is not built twice.

The mode in force is the one of the box that runs, read from the applied box
in the store. A revision that turns approval off therefore waits for approval
itself, and one that turns it on is applied at once. Two cases never wait: a
box's first build, which the person who installed it just asked for, and a
revision that builds the box already applied.

Approval decides when a change takes effect, and for a box without agents
whether it does. It is no gate against an agent inside the box: an agent that
runs as the box's user can run `denbox apply`, or change the home without the
environment. The build runs before the approval, and with it the revision's
Nix code; on a machine that is inside Nix's sandbox, in a container it is not
(see Hosts).

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
  `loginServer`, `tags`, `ssh`, `acceptDns` and `netfilterMode` with
  `tailscale up --reset`, so a setting changed by hand with `tailscale set`
  lasts until the next start. A sync that changes an option restarts the service.
- **Joining.** A box that is not logged in joins with the key in
  `/run/secrets/denbox_tailscale_authkey`, which the module declares as the
  secret `tailscale_authkey` that may be empty. The key comes from the host
  and not through the secrets provider, because a provider may itself be reachable
  only inside the tailnet. It is needed once; without it the service waits and
  `tailscale login` in the box prints a URL to log in by hand (with
  `--login-server` for another control server; the service's log names the
  command). Whether a node
  is short-lived is a property of the key (an ephemeral key removes the node
  when the box is gone), not of the box.
- **The tunnel.** By default the box has a tunnel device, so every program in
  it reaches the tailnet without knowing, and what it sends arrives as the
  box. The host has to grant that, and the module asks for it in
  `denbox.host`: the device `/dev/net/tun` and the capability `NET_ADMIN`,
  next to the key. `install.sh` shows the request and asks for the key. On a host
  that grants neither, `denbox.tailscale.userspace` runs the node without a
  device, and the module asks for the key only: the tailnet still reaches the box, and programs in the box reach
  the tailnet only through the proxy `tailscaled` then offers, SOCKS5 and
  HTTP on `127.0.0.1:1055`. A box without the device or the capability and
  without `userspace` does not fall back: its service says why and stays down.
- **Ports the host publishes.** With the tunnel, tailscaled's firewall rules
  drop every packet from the tailnet's range that does not come through the
  tunnel. A client that reaches the host over the tailnet and connects to a
  port the host publishes arrives with its tailnet address, so it is
  dropped. `denbox.tailscale.netfilterMode = "off"` keeps such connections;
  tailscaled still applies the tailnet's rules to the tunnel.
- **Serving.** `denbox.tailscale.serve.<name> = { port = 443; https = true;
  path = "/"; to = "http://127.0.0.1:3773"; }` publishes a local port to the
  tailnet with `tailscale serve`, under the node's name and, with `https`,
  the tailnet's certificate. Nothing is served unless the box says so: each
  start replaces what the node serves with these entries. A served port
  needs no port published by the host.
- **Another control server.** `denbox.tailscale.loginServer` points the node
  at a self-hosted control server. The module makes a box a node of one
  tailnet.
- **A second tailnet** is the environment's own service, never a second
  tunnel: two `tailscaled` with tunnels in one box overwrite each other's
  routes and resolver, and both tailnets use `100.64.0.0/10`. The second runs
  in userspace (`--tun=userspace-networking`) with its own state and socket,
  and is reached through its SOCKS5 proxy, or transparently with redirect
  rules in front of it, which the module's `NET_ADMIN` permits. Give the
  tunnel to the tailnet whose addresses the box's programs reach without
  configuration, keep that node's `acceptDns` off when the box has a
  resolver of its own, and leave the tunnel's destinations out of the
  redirect.

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
- **The host decides what a box gets.** A box asks for ports, devices,
  capabilities, host paths and secrets in its environment, so a commit can
  ask for more. The installer shows the request and starts the box only when
  a person accepts it, and asks again whenever it changed; a box that is
  running keeps what it was started with until then.
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
  secrets.api_key.description = "Key of the example API";
};
```

A secret is a file the host provides and keeps, such as a key: a name of
lowercase letters, digits and `_`, where it appears in the box (`target`,
by default `/run/secrets/denbox_<name>`, read-only), whether it may be empty,
and one line telling the person asked for it what it is. The Tailscale
module declares its key so. A secret is for what the box needs before its
secrets provider can run; anything else belongs to the provider.

Every value is typed narrowly enough that whatever evaluates can be written
into a Compose file or a systemd unit without quoting: paths and sizes of a
few characters, IPv4 addresses, capability names. A wrong value, or a host
port published twice, fails the evaluation with the option's name.

`nix eval --json <flake>#boxes.<name>.host` prints the declaration, and
`deploy/render` turns it into a deployment, adding what only the host knows:
the box's name, the image and where the bootstrap and token files are.

    deploy/render --format compose --name NAME --image IMAGE --bootstrap FILE --token FILE [--secret NAME=FILE]... HOST.json
    deploy/render --format quadlet --name NAME --image IMAGE --bootstrap FILE --token FILE [--secret NAME=FILE]... --output DIR HOST.json
    deploy/render --explain --name NAME HOST.json

`compose` prints one Compose file for the container `denbox-NAME`: home
and Nix volumes, the bootstrap and every declared secret as Compose secrets,
`/tmp` and `/run/denbox` as tmpfs, and the rest of the declaration.
Every declared secret needs one `--secret` and every `--secret` a declared
secret. `quadlet` writes the Podman
Quadlet units `denbox-NAME.container`, `denbox-NAME-home.volume` and
`denbox-NAME-nix.volume`. Relative file paths are relative to the Compose
project directory, or to the directory of the units. `--explain` prints what
the box asks for in words, with what weakens its isolation from the host
first, each marked `!`: capabilities, devices, host paths, ports bound beyond
loopback; then ports on loopback, secrets, limits and the resolver. The
script refuses, with status 65, a declaration it cannot express exactly, a
key it does not know included; it never drops one. It needs bash and jq,
and the image carries it as `/usr/local/share/denbox/render`.

A change to an environment's repository must not quietly hand a container
more of the host. `install.sh` shows the explanation before it starts a box,
and again, with the lines that changed, whenever it differs from the one
accepted last, and starts the box only when a person agrees (see Hosts).

## Hosts

A box needs Linux, Nix and something that runs `denbox supervise` at start.

- **Docker**, the first host. `image/` builds the image;
  `deploy/render --format compose` writes the deployment from the box's
  `denbox.host`, and `install.sh` starts it with Compose.
- **Podman**, rootless or not: the same image, deployed as Quadlet units
  from `deploy/render --format quadlet` and started as a systemd service,
  `systemctl --user start denbox-NAME` for a user's. Rootless Podman sets a
  memory, CPU or process limit only through a cgroup controller that systemd
  delegates to the user; most distributions delegate memory and pids, and
  cpu needs `Delegate=` in a drop-in for `user@.service`. On SELinux, the
  bootstrap and secret files are relabeled for the container; a bound host
  path is not.
- **Baked image**, for short-lived boxes: the same image with one box already
  built into its store, made by the environment's CI. It starts without a
  build and without volumes.
- **A machine**: a Debian or Ubuntu machine with systemd, a VPS for
  example, without a container. See below.
- **Incus**, later.

`install.sh` installs or updates one box on Docker or Podman; it needs bash
and the container runtime, and runs everything else in throwaway containers
of the image.

1. It asks for the environment repository, the branch, the box name and, for
   a private repository, a token, and pulls the image.
2. It evaluates `boxes.<box>.host` with `denbox host` in a container of the
   image over the box's Nix volume: the environment fetched at the branch
   and `follow` honoured as the sync does, nothing built. What the
   evaluation fetches stays in the store, so the box's first build does not
   fetch it again; on a first install it costs about as long as fetching and
   evaluating the environment's inputs takes, nixpkgs and Home Manager for a
   box of the kit. The bootstrap and the token go in on standard input,
   never on a command line or in a container's environment.
3. It shows `deploy/render --explain` and asks before it writes or starts
   anything. On an update it compares with the request accepted last, kept in
   `DIR/accepted`, and asks again only when it changed, listing the lines
   that went and came. `--accept` (`DENBOX_ACCEPT=1`) accepts without
   asking; an unattended run without it stops when the request changed.
4. It asks for every declared secret like the token: `--secret-file
   NAME=FILE`, the variable `DENBOX_SECRET_<NAME>`, or the terminal without
   echo. They are kept as mode-0600 files in `DIR/secrets` across updates.
5. It renders the deployment into the install directory and starts it:
   `--runtime docker` (the default where Docker is installed) runs
   `DIR/compose.yaml` with Compose; `--runtime podman` copies the units of
   `DIR/quadlet` to `~/.config/containers/systemd` and restarts the user
   service `denbox-NAME`.

### Moving an installation

An installation made before the installer read `denbox.host` keeps its
repository, branch, box, name and image in `.env`, and the next run of
`install.sh` reads them. The settings that shaped the container are now
options of the box, set in its environment:

| Former setting | Now |
| --- | --- |
| `DENBOX_BIND_IP` | `denbox.host.ports.<name>.address` |
| `DENBOX_T3_PORT`, `DENBOX_API_PORT` | `denbox.host.ports.t3.hostPort`, `denbox.host.ports.api.hostPort` |
| `DENBOX_CPUS`, `DENBOX_MEMORY`, `DENBOX_PIDS` | `denbox.host.cpus`, `.memory`, `.pids` |
| `install.sh --tailscale`, `deploy/compose.tailscale.yaml` | `denbox.tailscale.enable`, which asks for the device, the capability and the key |
| `--tailscale-authkey-file FILE`, `DENBOX_TAILSCALE_AUTHKEY` | `--secret-file tailscale_authkey=FILE`, `DENBOX_SECRET_TAILSCALE_AUTHKEY` |

A key already given stays where the box finds it if it is moved into the
secrets directory: `mkdir -p DIR/secrets && mv DIR/tailscale_authkey
DIR/secrets/`. `compose.tailscale.yaml` in the directory can be deleted.

### A machine

On a machine a box is one user: it manages that user's home and the
services that run as that user. It does not manage the system (kernel,
firewall, system packages, other users), and it is not isolated from the
machine: its agents can do whatever that user can.

`install-host.sh`, run as root, takes the same answers as `install.sh` and:

1. installs Nix with its daemon when Nix is missing, the same pinned release
   as the image. Multi-user Nix lets a box that is not root build, root and
   collect the store through the daemon, with the sandbox on, and needs
   none of the container's settings (`sandbox = false`, no build users). A
   Nix without its daemon is refused. It adds
   `extra-trusted-substituters` and `extra-trusted-public-keys` for the
   kit's binary cache to the daemon's `nix.conf`, so that the daemon takes
   them from the box's user; no other user gets the cache;
2. builds the seed runtime from this repository's default branch, or from
   the flake `--seed` names (a revision, a local checkout), rooted at
   `/nix/var/nix/gcroots/denbox-seed`. The seed runs only until the first
   activation installs the runtime the box's own lock names;
3. reads `boxes.<box>.config.home.username` and `.homeDirectory` and creates
   that user with that home when it is missing. The box says who it runs as;
   one user runs one box;
4. writes the bootstrap and the token, the unit `denbox-NAME.service` and the
   launcher `/usr/local/bin/denbox`, and restarts the unit.

Run again with the same name, it rewrites these files with the settings it
saved, rebuilds the seed and restarts the box. It never creates, changes or
deletes anything in the home.

| Path | Holds |
| --- | --- |
| `/etc/denbox/NAME/bootstrap.json`, `git_token` | the bootstrap, `root:GROUP` `0640` in a `0750` directory: root and the box's user read them, only root writes them |
| `/etc/denbox/NAME/settings` | what the installer reuses when run again, root only |
| `/etc/systemd/system/denbox-NAME.service` | runs `denbox supervise` as the user, restarts it always |
| `/usr/local/bin/denbox` | the image's launcher: the user's profile copy, the seed before it |
| `/run/denbox-USER/` (`/run/denbox/` for root) | the unit's `RuntimeDirectory`, empty at every start |

The unit sets `DENBOX_BOOTSTRAP`, `DENBOX_GIT_TOKEN` and `DENBOX_RUN`, and a
`PATH` with the user's profile and Nix first. The runtime finds the same run
directory by its user, so `denbox service ...` and `denbox shell` work in the
user's login shell. A `denbox sync --once` there needs the unit's two
bootstrap variables. The service logs go to the journal as well:
`journalctl -u denbox-NAME`.

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
deploy/, install.sh       deploy/render, its tests, the installer
install-host.sh           installer for a machine with systemd
template/                 what `nix flake init -t github:riprsa/denbox` writes
docs/                     this file
```
