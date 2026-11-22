# denbox

A box is a Linux workspace built from a flake: shell and tools, optionally T3
Code and coding agents, as Home Manager modules. The box follows a Git
repository you own, the environment, and applies every new commit on its own.
A box runs as a Docker container or straight on a Linux machine with systemd.

![A flake in your repository describes a box; on every push the box fetches it, builds it and activates it](docs/overview.svg)

- `kit/`: the Home Manager modules, `denbox-api`, the `denbox` runtime.
- `image/`: the container image, with Nix and a seed of the runtime.
- `template/`: an environment to start from.
- `extension/`: a browser extension that shows the box's state and runs
  browser parts from Git sources.

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
3. **The extension.** Load `extension/` unpacked and set its box address to
   the box's API, `http://127.0.0.1:48099` on the Docker host. The box only
   supplies data; code the extension runs comes from sources on a protected
   Git branch. See [extension/README.md](extension/README.md).

T3 Code listens on `127.0.0.1:3773` of the host.

## On a machine, without a container

On a Debian or Ubuntu machine with systemd, as root, run

```sh
bash install-host.sh
```

It asks the same questions as `install.sh`, installs Nix with its daemon when
it is missing, and runs the box as the user the box names in
`home.username` and `home.homeDirectory`, creating that user when needed. The
box becomes the unit `denbox-<box>.service`: `journalctl -u denbox-<box> -f`
for its logs, `su - <user> -c 'denbox shell'` for its shell. Run it again
with `--name <box>` to update. The box manages that user's home and services;
it does not manage the machine (kernel, firewall, system packages) and is not
isolated from it.

## More

- [docs/design.md](docs/design.md): the contracts between the parts, every
  option.
- [extension/README.md](extension/README.md), [template/README.md](template/README.md).
