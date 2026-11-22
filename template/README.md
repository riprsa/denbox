# My denbox environment

This flake describes one box, `main`, in `flake.nix`. Each `denbox.` option
there is commented; the full list is in denbox's `docs/design.md`.

## Edit

- `flake.nix`: switch T3 Code and the agents on or off, add packages, set a
  secrets provider. Add another box as another attribute next to `main`.
- `agent/AGENTS.md`: the instructions both agents read, linked into each
  agent's own place by `home.file`. Give each agent a file of its own, or
  add skills, the same way.

## Start

1. Check that the box builds: `nix build .#boxes.main`.
2. Push this flake to a Git repository.
3. Start a box from it on a Docker host with denbox's `install.sh`, giving
   it the repository, the branch and the box name `main`. The box syncs to
   every new commit on its own. On a machine without Docker, use
   `install-host.sh` instead.

## A box that does not run as root

A box runs as root with home `/root` unless it says otherwise. On a machine,
`install-host.sh` runs the box as the user it names and creates that user
when it is missing, so set both in the box's module:

```nix
home.username = "alice";
home.homeDirectory = "/home/alice";
```

An existing user must have that home in `/etc/passwd` and a primary group of
its own. In a container the box keeps running as root.
