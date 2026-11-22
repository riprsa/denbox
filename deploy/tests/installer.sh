#!/usr/bin/env bash
# shellcheck disable=SC2016 # scripts in single quotes run later, in the box
# End-to-end test of install.sh: the real installer, unattended, against a
# fixture environment in a local Git repository that git daemon serves on
# this machine's address. It accepts the request, waits for the box to apply
# and checks its secret; an update with the same request needs no
# acceptance, and one with a changed request stops without it.
#
#   deploy/tests/installer.sh IMAGE
#
# DENBOX_TEST_CLI is the runtime, docker (the default) or podman; podman
# needs a user systemd with Quadlet. Creates the box denbox-test-install-$$
# and its two volumes (and for podman its units in
# ~/.config/containers/systemd), and removes them by name when done.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: installer.sh IMAGE' >&2; exit 64; }
image=$1
cli=${DENBOX_TEST_CLI:-docker}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
name=test-install-$$
box=denbox-$name
units=${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd
port=$((20000 + $$ % 10000))
tmp=$(mktemp -d)
daemon=''
cleanup() {
  if [[ $cli == podman ]]; then
    systemctl --user stop "$box.service" > /dev/null 2>&1 || true
    rm -f "$units/$box.container" "$units/$box-home.volume" "$units/$box-nix.volume"
    systemctl --user daemon-reload || true
  fi
  "$cli" rm -f "$box" > /dev/null 2>&1 || true
  "$cli" volume rm "$box-home" "$box-nix" > /dev/null 2>&1 || true
  [[ -z $daemon ]] || kill "$daemon" 2> /dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*" >&2
  "$cli" exec "$box" sh -c 'cat /root/.local/state/denbox/status; tail -n 40 /root/.local/state/denbox/logs/*/current' >&2 ||
    "$cli" logs --tail 80 "$box" >&2 || true
  exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

# The fixture: a box without the kit whose service worker copies the secret
# into the home, and which asks for 1g, no ports and that secret.
mkdir -p "$tmp/srv/environment"
cat > "$tmp/srv/environment/flake.nix" <<'EOF'
{
  outputs = { self }:
    let
      box = system: derivation {
        name = "denbox-test-install";
        inherit system;
        builder = "/bin/sh";
        args = [ "-c" ''
          /bin/mkdir -p $out/services/worker
          /bin/cat > $out/services/worker/run <<SCRIPT
          #!/bin/sh
          /bin/cat /run/secrets/denbox_example > "\$HOME/secret-seen"
          exec /bin/sleep 100000
          SCRIPT
          /bin/cat > $out/activate <<SCRIPT
          #!/bin/sh
          /bin/mkdir -p "\$HOME/.config/denbox/services"
          /bin/ln -sfn $out/services/worker "\$HOME/.config/denbox/services/worker"
          SCRIPT
          /bin/chmod +x $out/activate $out/services/worker/run
        '' ];
      } // { follow = { }; host = builtins.fromJSON (builtins.readFile ./host.json); };
    in
    {
      legacyPackages = builtins.listToAttrs (map
        (system: { name = system; value.boxes.test = box system; })
        [ "x86_64-linux" "aarch64-linux" ]);
    };
}
EOF
# host MEMORY: writes the declaration with that memory limit.
host() {
  jq -n --arg memory "$1" '{binds: [], capabilities: [], cpus: 2, devices: [], dns: [], memory: $memory,
    pids: 2048, ports: {}, shmSize: "64m", tmpSize: null,
    secrets: {example: {target: "/run/secrets/denbox_example", allowEmpty: false, description: "Fixture secret"}}}' \
    > "$tmp/srv/environment/host.json"
}
commit() { git -C "$tmp/srv/environment" add -A && git -C "$tmp/srv/environment" -c user.name=test -c user.email=test@example.com commit -qm "$1"; }
host 1g
git init -q -b main "$tmp/srv/environment" && commit one

# Containers reach the daemon at this machine's own address.
address=$(hostname -I | cut -d' ' -f1)
git daemon --base-path="$tmp/srv" --export-all --reuseaddr --listen=0.0.0.0 --port="$port" "$tmp/srv" &
daemon=$!
for ((attempt = 0; attempt < 50; attempt++)); do
  git ls-remote "git://127.0.0.1:$port/environment" > /dev/null 2>&1 && break
  sleep .2
done

# install ARGS: the installer, unattended, for this box.
install() {
  bash "$root/install.sh" --repository "git://$address:$port/environment" --box test --name "$name" \
    --dir "$tmp/install" --image "$image" --runtime "$cli" "$@" < /dev/null
}

echo "# the installer shows the request, starts the box with --accept, and the box applies ($cli)"
DENBOX_SECRET_EXAMPLE=fixture-value install --accept > "$tmp/out" 2>&1 || fail "install: $(cat "$tmp/out")"
grep -q 'secret example at /run/secrets/denbox_example: Fixture secret' "$tmp/out" || fail "no request shown: $(cat "$tmp/out")"
for ((attempt = 0; ; attempt++)); do
  if "$cli" exec "$box" denbox service status worker 2> /dev/null | grep -q '^worker: up '; then break; fi
  ((attempt < 150)) || fail 'timed out waiting for the worker'
  sleep 2
done
[[ $("$cli" exec "$box" cat /root/secret-seen) == fixture-value ]] || fail 'the secret did not reach the box'
[[ $("$cli" exec "$box" cat /sys/fs/cgroup/memory.max) == 1073741824 || $cli == podman ]] || fail 'memory limit'
[[ $(stat -c %a "$tmp/install/secrets/example") == 600 ]] || fail 'the secret file is not 0600'
id=$("$cli" inspect -f '{{.Id}}' "$box")

echo '# an update with the same request needs no acceptance'
install > "$tmp/out" 2>&1 || fail "update: $(cat "$tmp/out")"
grep -q 'accepted before' "$tmp/out" || fail "asked again: $(cat "$tmp/out")"
[[ $("$cli" inspect -f '{{.Id}}' "$box") != "$id" ]] || fail 'the box was not recreated'
id=$("$cli" inspect -f '{{.Id}}' "$box")

echo '# an update with a changed request stops without acceptance and leaves the box'
host 2g
commit two
if install > "$tmp/out" 2>&1; then fail 'a changed request was started unattended'; fi
grep -q '^+   memory 2g' "$tmp/out" || fail "the change is not shown: $(cat "$tmp/out")"
[[ $("$cli" inspect -f '{{.Id}} {{.State.Running}}' "$box") == "$id true" ]] || fail 'the box was touched'

echo 'installer test passed'
