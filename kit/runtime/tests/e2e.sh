#!/usr/bin/env bash
# shellcheck disable=SC2016 # scripts in single quotes run later, in another shell
# End-to-end test of the image: a container without network whose bootstrap
# points at tests/fixture, served as Git repositories under /srv in the
# container itself.
#
#   kit/runtime/tests/e2e.sh IMAGE
#
# DENBOX_TEST_CLI is the container command, docker (the default) or podman,
# rootless or not. Creates the container denbox-test-e2e-$$ and its two
# volumes, and removes them by name when done.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: e2e.sh IMAGE' >&2; exit 64; }
image=$1
cli=${DENBOX_TEST_CLI:-docker}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
name=denbox-test-e2e-$$
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
  "$cli" logs --tail 80 "$name" >&2 || true
  exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

box() { "$cli" exec "$name" "$@"; }
# in_box SCRIPT: runs a shell script in the container.
in_box() { "$cli" exec "$name" bash -euo pipefail -c "$1"; }
wait_for() {
  for ((attempt = 0; attempt < 150; attempt++)); do
    if in_box "$1" > /dev/null 2>&1; then return 0; fi
    sleep 2
  done
  fail "timed out waiting for: $1"
}
version() { box cat /root/worker-version; }

# The fixture: the environment and the repository of its input extra.
mkdir -p "$tmp/srv/environment" "$tmp/secrets"
cp "$here/fixture/flake.nix" "$tmp/srv/environment/"
echo 1 > "$tmp/srv/environment/version"
commit() { git -C "$1" add -A && git -C "$1" -c user.name=test -c user.email=test@example.com commit -qm "$2"; }
git init -q -b main "$tmp/srv/environment" && commit "$tmp/srv/environment" one
git init -q -b old "$tmp/srv/extra"
echo old > "$tmp/srv/extra/value" && commit "$tmp/srv/extra" old
git -C "$tmp/srv/extra" switch -q -c main
echo main-1 > "$tmp/srv/extra/value" && commit "$tmp/srv/extra" main-1
jq -n '{version: 2, repository: "file:///srv/environment", ref: "main", box: "test",
  sync_interval: 30, apply_timeout: 600}' > "$tmp/secrets/denbox_bootstrap"
: > "$tmp/secrets/denbox_git_token"

"$cli" volume create "$home" > /dev/null
"$cli" volume create "$store" > /dev/null
"$cli" create --name "$name" --network none --memory 1g --cpus 2 --pids-limit 1024 \
  --tmpfs /run/denbox:mode=0700 -v "$home:/root" -v "$store:/nix" "$image" > /dev/null
# As root's files whoever runs this test: Git refuses a repository that
# another user owns, and "$cli" cp keeps the owner of what it copies.
tar -C "$tmp/srv" --owner=0 --group=0 -c . | "$cli" cp - "$name:/srv"
tar -C "$tmp" --owner=0 --group=0 -c secrets | "$cli" cp - "$name:/run"
"$cli" start "$name" > /dev/null
# Later commits are made in the container, with an identity of their own.
in_box 'git config --global user.name test && git config --global user.email test@example.com'

echo '# the box applies the environment and supervises its service, following extra to main'
wait_for 'denbox service status worker | grep "^worker: up "'
[[ $(version) == '1 main-1' ]] || fail "version $(version)"
box denbox service status | grep '^denbox-sync: up ' > /dev/null || fail 'sync loop not supervised'
[[ $(box getent passwd root | cut -d: -f7) == /usr/local/libexec/denbox/login ]] || fail 'login shell'
[[ $(box sh -c 'ls /usr/local/bin') == $'denbox\nnix' ]] || fail "commands of the image on PATH: $(box sh -c 'ls /usr/local/bin' | tr '\n' ' ')"

echo '# the seed runtime brings ssh, for Git inputs fetched before the first activation'
box bash -c 'tools=$(sed -n "s/^tools=//p" "$(readlink -f /nix/var/nix/gcroots/denbox-seed/libexec/denbox/denbox)")
  PATH=$tools command -v ssh' > /dev/null || fail 'no ssh on the seed runtime PATH'

echo '# a second supervisor is refused and the first keeps its services'
result=0
box timeout 20 denbox supervise 2>/dev/null || result=$?
[[ $result == 75 ]] || fail "a second supervise exited $result"
box denbox service status worker | grep '^worker: up ' > /dev/null || fail 'worker not up after a second supervise'
[[ $(box denbox shell -c 'echo ok') == ok ]] || fail 'denbox shell'
in_box 'printf "#!/bin/sh\necho ok\n" > /tmp/exec && chmod +x /tmp/exec && [ "$(/tmp/exec)" = ok ]' || fail '/tmp is noexec'

echo '# a new commit is applied by sync --once'
box denbox service stop denbox-sync
in_box 'echo 2 > /srv/environment/version && git -C /srv/environment commit -qam two'
box denbox sync --once
wait_for '[ "$(cat /root/worker-version)" = "2 main-1" ]'

echo '# a followed branch is resolved on every sync and built only when it moved'
output=$(box denbox sync --once 2>&1) || fail "sync --once: $output"
[[ $output != *Building* ]] || fail "an unchanged followed branch was built: $output"
in_box 'echo main-2 > /srv/extra/value && git -C /srv/extra commit -qam main-2'
box denbox sync --once
wait_for '[ "$(cat /root/worker-version)" = "2 main-2" ]'

echo '# a commit that fails to build leaves the previous state running'
revision=$(box cat /root/.local/state/denbox/revision)
in_box 'touch /srv/environment/broken && git -C /srv/environment add broken && git -C /srv/environment commit -qm broken'
if box denbox sync --once; then fail 'a broken build reported success'; fi
[[ $(box cat /root/.local/state/denbox/revision) == "$revision" ]] || fail 'revision changed'
box denbox service status worker | grep '^worker: up ' > /dev/null || fail 'worker not up'
[[ $(version) == '2 main-2' ]] || fail "version $(version)"

echo '# a restart without its repository comes back from the applied state'
in_box 'mv /srv/environment /srv/gone'
starts=$(in_box 'wc -l < /root/worker-starts')
"$cli" restart -t 60 "$name" > /dev/null
wait_for "[ \$(wc -l < /root/worker-starts) -gt $starts ] && denbox service status worker | grep '^worker: up '"
wait_for 'grep "failed exit=" /root/.local/state/denbox/status'
[[ $(version) == '2 main-2' ]] || fail "version $(version)"

echo 'end-to-end test passed'
