# denbox

A box is a Linux workspace built from a flake: shell and tools, optionally T3
Code and coding agents, as Home Manager modules. The box follows a Git
repository you own, the environment, and applies every new commit on its own.
Today a box runs as a Docker container.

- `kit/`: the Home Manager modules, `denbox-api`, the `denbox` runtime.
- `image/`: the container image, with Nix and a seed of the runtime.
- `template/`: an environment to start from.
- `extension/`: a browser extension that shows the box's state.

## Quick start

1. **An environment.** Copy `template/` into a new Git repository (or run
   `nix flake init -t github:riprsa/denbox` in one), edit `flake.nix` and push.
   See [template/README.md](template/README.md).
2. **A box.** On a host with Docker and Compose, run

   ```sh
   bash install.sh
   ```

   It asks for the repository URL, the branch, the box name and, for a
   private repository, a token that can read it. It writes the installation
   to `./denbox-<box>`, creates the box's home and Nix volumes and starts the
   box. The first build takes a while; follow it with
   `cd denbox-<box> && docker compose logs -f box`. Run the installer again
   with the same `--dir` to update the image. `bash install.sh --help` and
   the top of the script list the options for unattended use.
3. **The extension.** Load `extension/` unpacked and set its address to the
   box's API, `http://127.0.0.1:48099` on the Docker host. See
   [extension/README.md](extension/README.md).

T3 Code listens on `127.0.0.1:3773` of the host.

## More

- [docs/design.md](docs/design.md): the contracts between the parts, every
  option.
- [extension/README.md](extension/README.md), [template/README.md](template/README.md).
