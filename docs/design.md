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
| Kit | `kit/`, a flake input of every environment | Home Manager modules, packages, `denbox-api`, the runtime, browser parts | often |
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
        denbox.agents.instructions = ./agent/AGENTS.md;
        denbox.agents.skills = ./agent/skills;
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
| `denbox.browser.parts.<name>` | `{ }` | browser code served to the extension (see Browser) |
| `denbox.t3.enable` | `false` | T3 Code as a service |
| `denbox.t3.package` | kit's pin | override to patch or repin |
| `denbox.t3.port`, `.host`, `.projects`, `.settings` | `3773`, `0.0.0.0`, `~/Projects`, `{ }` | `.settings` is merged into T3's `settings.json` on start |
| `denbox.agents.claude.enable`, `.package` | `false`, kit's pin | Claude Code |
| `denbox.agents.codex.enable`, `.package` | `false`, kit's pin | Codex |
| `denbox.agents.instructions` | `null` | a Markdown file given to every enabled agent as its user-wide instructions |
| `denbox.agents.extraInstructions` | `""` | lines appended to it |
| `denbox.agents.skills` | `null` | a directory of skills given to every enabled agent |
| `denbox.agents.mcpServers` | `{ }` | MCP servers registered with every enabled agent |
| `denbox.secrets.provider` | passthrough | see Secrets |
| `denbox.follow` | `{ }` | flake input name to flake reference (see Sync) |

An MCP server is `{ command, args, env }` or `{ url, headers }`. Claude gets
them merged into `~/.claude.json` on activation; Codex gets them as `-c`
overrides on its command line, so `~/.codex/config.toml` stays Codex's own.

An agent that needs a proxy, a wrapper or another build overrides its
`.package`. The kit knows nothing about a particular proxy, vault or cluster.

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

One command, `denbox`, replaces the set of commands the predecessor had:

    denbox supervise                      PID 1 after tini: s6 over the services and the sync loop
    denbox sync [--once]                  fetch, build, activate, reconcile services
    denbox service status [NAME]
    denbox service start|stop|restart NAME
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
   every entry of `follow`.
4. Run `<box>/activate`, then reconcile the supervised services with
   `~/.config/denbox/services`.

A failed fetch, build or activation keeps the box as it was. A box restarts
from its last applied state without network.

A box without `follow` skips steps 3 and 4 while the revision is the one it
applied (it still reconciles). A box with `follow` builds at every sync with
`--refresh`, so Nix looks at the followed branches again, and activates only
when the build's store path changed. After an activation, at most once a day,
the runtime keeps three generations of the user's profiles and collects the
store.

`denbox.follow` is how a kit update reaches boxes without a commit to every
environment. `denbox.follow.denbox = "github:riprsa/denbox";` makes the box
build against the kit's current `main` at every sync, whatever the
environment's `flake.lock` says. Without it the lock decides, and a kit update
arrives when the environment updates its lock. The default is empty.

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
door. Every request must carry the header `x-denbox-api: 1`; a web page cannot
send it cross-origin without a preflight the server never answers.

| Route | Does |
| --- | --- |
| `GET /state` | `{ system, services, ports }`; a failing section is `{"state":"unavailable","reason":"..."}` |
| `POST /services/restart` | `{ "name": "..." }` |
| `POST /services/toggle` | `{ "name": "...", "on": true }`, optional services only |
| `GET /bundle.json` | the browser bundle of this box; 404 when it has no parts |

It talks to the supervisor only through `denbox service ...`.

## Browser

`extension/` is a browser extension that holds no feature of its own. It has a
loader, an options page and the permissions features need. Its options take
one value, the address of a box's API. The loader fetches
`<address>/bundle.json` every 5 minutes with the `x-denbox-api` header and
runs it.

A bundle is

```json
{ "version": 1, "parts": { "<name>": { "background": "...", "content": [ { "matches": ["..."], "js": "..." } ], "pages": { "<page>": { "html": "...", "js": "..." } } } } }
```

Each part starts on its own; one that throws does not stop the others. A
bundle that fails to parse leaves the previous one running.

`denbox.browser.parts.<name>` in a box has the same shape as a part, with file
paths in place of text. A part without `background` leaves the key out;
`content` and `pages` may be empty. The kit builds the bundle from all parts at
build time and `denbox-api` serves it. The kit ships the part `panel` (the box's state,
services and ports, from `/state`), on when `denbox.api.enable` is. An
environment adds its own parts next to it.

The extension keeps the manifest key of the extension it replaces, so its id
and the origins that trust it do not change.

## Hosts

A box needs Linux, Nix and something that runs `denbox supervise` at start.

- **Docker**, the first host. `image/` builds the image; `deploy/compose.yaml`
  is the standard deployment (home and Nix volumes, the two bootstrap
  secrets, loopback ports). An environment can add Compose overlays from its
  repository.
- **Baked image**, for short-lived boxes: the same image with one box already
  built into its store, made by the environment's CI. It starts without a
  build and without volumes.
- **VPS and Incus**, later: a NixOS module that runs `denbox supervise` as a
  unit.

`install.sh` asks for the environment repository, the box name and, for a
private repository, a token. It pulls the public image and starts Compose.

## Repository

```
flake.nix, flake.lock     lib.mkBoxes, homeManagerModules.default, packages, checks, templates.default
kit/go.mod, api/, cmd/    denbox-api
kit/nix/modules/          one file per option group
kit/nix/packages/         pins and builds: denbox-api, the browser bundle, t3, claude, codex, runtime
kit/nix/checks/           flake checks beyond the package builds
kit/runtime/              the denbox command
kit/browser/<part>/       sources of the parts the kit ships
extension/                the browser extension
image/                    Dockerfile and its init
deploy/, install.sh       standard Compose deployment and installer
template/                 what `nix flake init -t github:riprsa/denbox` writes
docs/                     this file
```

## Build order

1. `denbox-api`, the services module, checks, CI.
2. The extension and the `panel` part.
3. The remaining kit modules, `mkBoxes`, the template.
4. The runtime, the image, the installer, an end-to-end test that starts a box
   from the template in CI.
5. The first environments move over. A box is cut over by installing it next
   to the old one, checking it, then switching the front door.
6. Baked images, a binary cache, the NixOS module.
