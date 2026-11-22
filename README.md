# denbox

A box is a Linux workspace built from a flake: shell and tools, optionally T3
Code and coding agents, as Home Manager modules. The box follows a Git
repository you own, the environment, and applies every new commit on its own.
Today a box runs as a Docker container.

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

## A box in a tailnet

By default a box shares its host's place in the network: it is reached
through ports the host publishes, and whatever it sends leaves as the host,
so an agent in the box reaches everything the host reaches. With
`denbox.tailscale.enable` the box is a Tailscale node of its own, with its own
name, address and entry in the tailnet's access rules, and
`denbox.tailscale.serve` publishes its ports to the tailnet with the
tailnet's certificate instead of through the host.

- **The host** grants the tunnel device and the key:
  `bash install.sh --tailscale` adds
  [deploy/compose.tailscale.yaml](deploy/compose.tailscale.yaml) and asks for
  an auth key without echo (or reads `--tailscale-authkey-file`). The key is
  used once, at the first start; leave it empty to run `tailscale login` in
  the box instead. A host that grants no device runs the box with
  `denbox.tailscale.userspace = true`.
- **Tag the node and restrict it.** Ask for a tag such as `tag:denbox` in
  `denbox.tailscale.tags`, create the key for that tag, and give the tag
  only the access a box needs in the tailnet's rules. A box in a tailnet
  without rules for it reaches the whole tailnet, which only moves the
  problem.

See the commented example in [template/flake.nix](template/flake.nix) and
the section Tailscale of [docs/design.md](docs/design.md).

## More

- [docs/design.md](docs/design.md): the contracts between the parts, every
  option.
- [extension/README.md](extension/README.md), [template/README.md](template/README.md).
