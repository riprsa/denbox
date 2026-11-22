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
| `/run/denbox/` | s6 scan directory (`services/`) and locks; gone on restart, and may be `noexec`. `/run/denbox-USER/` for a box whose user is not root |
| `/run/secrets/denbox_bootstrap`, `/run/secrets/denbox_git_token` | the bootstrap, mounted by the host; a machine passes other paths (see Hosts) |

One command, `denbox`, replaces the set of commands the predecessor had:

    denbox supervise                      s6 over the services and the sync loop, under tini or systemd; refused while one runs
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

## Secrets

The kit never reads a vault. `denbox.secrets.provider` is an executable called
as

    PROVIDER CONSUMER -- COMMAND [ARGS...]

It must exec `COMMAND` with the environment variables meant for `CONSUMER`.
The kit's services call it with these consumers: `shell` for interactive
shells, `agents` for Claude and Codex, `t3` for T3 Code. The default provider
adds nothing and execs the command. An environment points the option at its
own program (a secrets broker, sops, a file reader).

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

## Hosts

A box needs Linux, Nix and something that runs `denbox supervise` at start.

- **Docker**, the first host. `image/` builds the image; `deploy/compose.yaml`
  is the standard deployment (home and Nix volumes, the two bootstrap
  secrets, loopback ports). An environment can add Compose overlays from its
  repository.
- **Baked image**, for short-lived boxes: the same image with one box already
  built into its store, made by the environment's CI. It starts without a
  build and without volumes.
- **A machine**: a Debian or Ubuntu machine with systemd, a VPS for
  example, without a container. See below.
- **Incus**, later.

`install.sh` asks for the environment repository, the box name and, for a
private repository, a token. It pulls the public image and starts Compose.

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
   Nix without its daemon is refused;
2. builds the seed runtime from this repository at a pinned revision, or
   from the flake `--seed` names, rooted at `/nix/var/nix/gcroots/denbox-seed`;
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
deploy/, install.sh       standard Compose deployment and installer
install-host.sh           installer for a machine with systemd
template/                 what `nix flake init -t github:riprsa/denbox` writes
docs/                     this file
```
