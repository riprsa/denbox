#!/usr/bin/env bash
# shellcheck disable=SC2016 # scripts in single quotes run later, in the box
# Starts the end-to-end fixture box from Quadlet units that deploy/render
# wrote, as a user service of rootless Podman, and waits for the box to
# apply its environment. The fixture repositories are a host path bound in
# read-only, which is how the declaration's binds reach the units.
#
#   deploy/tests/quadlet.sh IMAGE
#
# Needs a user systemd (loginctl enable-linger) and Podman with Quadlet.
# Installs the units denbox-test-quadlet* into ~/.config/containers/systemd
# and removes them, the container and its two volumes when done.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: quadlet.sh IMAGE' >&2; exit 64; }
image=$1
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
name=test-quadlet
units=${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd
tmp=$(mktemp -d)
cleanup() {
  systemctl --user stop "denbox-$name.service" > /dev/null 2>&1 || true
  rm -f "$units/denbox-$name.container" "$units/denbox-$name-home.volume" "$units/denbox-$name-nix.volume"
  systemctl --user daemon-reload || true
  podman rm -f "denbox-$name" > /dev/null 2>&1 || true
  podman volume rm "denbox-$name-home" "denbox-$name-nix" > /dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*" >&2
  journalctl --user -u "denbox-$name.service" --no-pager -n 80 >&2 || true
  exit 1
}

# The fixture of kit/runtime/tests/e2e.sh, made the same way.
mkdir -p "$tmp/srv/environment" "$tmp/files"
cp "$root/kit/runtime/tests/fixture/flake.nix" "$tmp/srv/environment/"
echo 1 > "$tmp/srv/environment/version"
commit() { git -C "$1" add -A && git -C "$1" -c user.name=test -c user.email=test@example.com commit -qm "$2"; }
git init -q -b main "$tmp/srv/environment" && commit "$tmp/srv/environment" one
git init -q -b old "$tmp/srv/extra"
echo old > "$tmp/srv/extra/value" && commit "$tmp/srv/extra" old
git -C "$tmp/srv/extra" switch -q -c main
echo main-1 > "$tmp/srv/extra/value" && commit "$tmp/srv/extra" main-1
jq -n '{version: 2, repository: "file:///srv/environment", ref: "main", box: "test",
  sync_interval: 30, apply_timeout: 600}' > "$tmp/files/bootstrap.json"
: > "$tmp/files/git_token"

# What the fixture box asks for: the defaults, no ports, the repositories.
jq -n --arg srv "$tmp/srv" '{binds: [{source: $srv, target: "/srv", readOnly: true}], capabilities: [],
  cpus: 2, devices: [], dns: [], memory: "2g", pids: 2048, ports: {}, secrets: {}, shmSize: "64m", tmpSize: null}' \
  > "$tmp/host.json"
"$root/deploy/render" --format quadlet --name "$name" --image "$image" \
  --bootstrap "$tmp/files/bootstrap.json" --token "$tmp/files/git_token" --output "$tmp/units" "$tmp/host.json"

echo "# Podman's generator accepts the units"
QUADLET_UNIT_DIRS=$tmp/units /usr/libexec/podman/quadlet -dryrun -user > "$tmp/generated" ||
  fail "quadlet refused the units: $(cat "$tmp/generated")"
grep -q "^ExecStart=.*podman run .*--name=denbox-$name " "$tmp/generated" || fail "no service generated: $(cat "$tmp/generated")"

echo '# the box starts as a user service and applies its environment'
mkdir -p "$units"
cp "$tmp/units"/* "$units/"
systemctl --user daemon-reload
systemctl --user start "denbox-$name.service" || fail 'the service did not start'
for ((attempt = 0; ; attempt++)); do
  if podman exec "denbox-$name" denbox service status worker 2> /dev/null | grep -q '^worker: up '; then break; fi
  ((attempt < 150)) || fail 'timed out waiting for the worker'
  sleep 2
done
[[ $(podman exec "denbox-$name" cat /root/worker-version) == '1 main-1' ]] || fail 'wrong version'
[[ $(podman exec "denbox-$name" hostname) == "$name" ]] || fail 'wrong hostname'
# The limits need the controllers delegated to the user.
[[ $(podman exec "denbox-$name" cat /sys/fs/cgroup/memory.max) == 2147483648 ]] || fail 'memory limit'
[[ $(podman exec "denbox-$name" cat /sys/fs/cgroup/pids.max) == 2048 ]] || fail 'pids limit'
[[ $(podman exec "denbox-$name" cat /sys/fs/cgroup/cpu.max) == '200000 100000' ]] || fail 'cpu limit'
[[ $(podman exec "denbox-$name" stat -f -c %T /tmp) == tmpfs ]] || fail '/tmp is not a tmpfs'

echo '# stopping the service keeps the volumes'
systemctl --user stop "denbox-$name.service"
for volume in home nix; do podman volume exists "denbox-$name-$volume" || fail "the volume $volume is gone"; done

echo 'quadlet test passed'
