#!/usr/bin/env bash
# shellcheck disable=SC2016 # scripts in single quotes run later, in another shell
# End-to-end test of a real box: a container of the image whose bootstrap
# points at an environment made from template/, with its denbox input
# pointed at this checkout. It builds the template's box with the network:
# nixpkgs, Home Manager, T3 Code and both agents.
#
#   kit/runtime/tests/box.sh IMAGE
#
# Creates the container denbox-test-box-$$ and its two volumes, and removes
# them by name when done. DENBOX_TEST_MEMORY sets the container's memory
# limit (default 4g); DENBOX_TEST_CLI is the container command, docker (the
# default) or podman.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: box.sh IMAGE' >&2; exit 64; }
image=$1
cli=${DENBOX_TEST_CLI:-docker}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
name=denbox-test-box-$$
home=$name-home
store=$name-nix
tmp=$(mktemp -d)
cleanup() {
  "$cli" rm -fv "$name" > /dev/null 2>&1 || true
  "$cli" volume rm "$home" "$store" > /dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*" >&2
  "$cli" exec "$name" sh -c 'cd /root/.local/state/denbox && cat status; denbox service status
    for log in logs/*/current; do echo "== $log"; tail -n 40 "$log"; done' >&2 ||
    "$cli" logs --tail 80 "$name" >&2 || true
  exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

box() { "$cli" exec "$name" "$@"; }
# in_box SCRIPT: runs a shell script in the container.
in_box() { "$cli" exec "$name" bash -euo pipefail -c "$1"; }
# wait_for SECONDS SCRIPT: until SCRIPT succeeds in the container.
wait_for() {
  local deadline=$((SECONDS + $1))
  until in_box "$2" > /dev/null 2>&1; do
    ((SECONDS < deadline)) || fail "timed out waiting for: $2"
    sleep 5
  done
}

# The kit: this checkout's files as they are, tracked or new, served as a path.
mkdir -p "$tmp/srv/denbox" "$tmp/srv/environment" "$tmp/secrets"
git -C "$root" ls-files -z -co --exclude-standard | (cd "$root" && tar --null -T - -cf -) | tar -x -C "$tmp/srv/denbox"
# The image's seed is built from this checkout too. A changed line gives the
# box a runtime of its own, so the switch from the seed to it happens.
echo '# changed by box.sh' >> "$tmp/srv/denbox/kit/runtime/denbox"
# The environment: the template with its denbox input pointed at the kit.
cp -R "$root/template/." "$tmp/srv/environment/"
sed -i 's|inputs.denbox.url = "github:riprsa/denbox";|inputs.denbox.url = "path:/srv/denbox";|' "$tmp/srv/environment/flake.nix"
grep -q 'path:/srv/denbox' "$tmp/srv/environment/flake.nix" || fail 'the template has no denbox input to point at the kit'
git init -q -b main "$tmp/srv/environment"
git -C "$tmp/srv/environment" add -A
git -C "$tmp/srv/environment" -c user.name=test -c user.email=test@example.com commit -qm environment
jq -n '{version: 2, repository: "file:///srv/environment", ref: "main", box: "main", apply_timeout: 3600}' \
  > "$tmp/secrets/denbox_bootstrap"
: > "$tmp/secrets/denbox_git_token"

"$cli" volume create "$home" > /dev/null
"$cli" volume create "$store" > /dev/null
"$cli" create --name "$name" --memory "${DENBOX_TEST_MEMORY:-4g}" --cpus 2 --pids-limit 2048 \
  --tmpfs /run/denbox:mode=0700 --tmpfs /tmp:mode=1777,exec \
  -v "$home:/root" -v "$store:/nix" "$image" > /dev/null
# As root's files whoever runs this test: Git refuses a repository that
# another user owns, and the cp command keeps the owner of what it copies.
tar -C "$tmp/srv" --owner=0 --group=0 -c . | "$cli" cp - "$name:/srv"
tar -C "$tmp" --owner=0 --group=0 -c secrets | "$cli" cp - "$name:/run"
"$cli" start "$name" > /dev/null

echo '# the first sync builds and activates the box as root'
seed=$(box readlink -f /nix/var/nix/gcroots/denbox-seed/bin/denbox)
wait_for 3600 'grep -q " applied " /root/.local/state/denbox/status'
box test -e /root/.local/state/denbox/applied || fail 'no applied box'
[[ $(box id -u) == 0 ]] || fail 'not root'

echo "# the runtime restarts into the box's own copy"
own=$(box readlink -f /root/.nix-profile/bin/denbox)
[[ -n $own && $own != "$seed" ]] || fail "the profile's runtime $own is the seed's"
wait_for 120 'pid=$(denbox service status denbox-sync | sed -n "s/.*: up (pid \([0-9]*\).*/\1/p")
  [ -n "$pid" ] && tr "\0" " " < /proc/$pid/cmdline | grep -q " /root/.nix-profile/bin/denbox sync"'
box grep -q 'The runtime changed' /root/.local/state/denbox/logs/denbox-sync/current || fail 'the sync loop did not restart'

echo '# denbox-api and t3 stay up'
for service in denbox-api t3; do
  wait_for 120 "denbox service status $service | grep -Eq '^$service: up \\(pid [0-9]+[^)]*\\) ([2-9][0-9]|[0-9]{3,}) seconds'"
done

echo '# denbox-api answers with the header and refuses without it'
curl=/root/.nix-profile/bin/curl
state=$(box "$curl" -fsS -H 'x-denbox-api: 1' http://127.0.0.1:48099/state)
jq -e '(keys == ["ports", "services", "system"]) and all(.[]; type != "object" or .state != "unavailable")' \
  <<<"$state" > /dev/null || fail "state: $state"
jq -e '[.services[].name] | index("t3") and index("denbox-api")' <<<"$state" > /dev/null || fail "services: $state"
code=$(box "$curl" -s -o /dev/null -w '%{http_code}' http://127.0.0.1:48099/state)
[[ $code == 403 ]] || fail "request without the header answered $code"

echo '# the agents run and denbox shell is fish'
box claude --version
box codex --version
[[ $(box denbox shell -c 'echo ok') == ok ]] || fail 'denbox shell -c'
[[ -n $(box denbox shell -c 'echo $FISH_VERSION') ]] || fail 'denbox shell is not fish'

echo '# a second sync with nothing changed does not rebuild'
box denbox service stop denbox-sync
applied=$(box readlink -f /root/.local/state/denbox/applied)
output=$(box denbox sync --once 2>&1) || fail "sync --once: $output"
[[ $output != *Building* && $output != *Activating* ]] || fail "sync rebuilt: $output"
[[ $(box readlink -f /root/.local/state/denbox/applied) == "$applied" ]] || fail 'applied box changed'

echo 'real-box test passed'
