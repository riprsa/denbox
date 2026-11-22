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
   every new commit on its own.
