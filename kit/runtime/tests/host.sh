#!/usr/bin/env bash
# shellcheck disable=SC2016 # scripts in single quotes run later, as the box's user
# End-to-end test of install-host.sh on a machine with systemd: installs Nix,
# creates the user boxuser and runs the box of tests/host-fixture as that
# user, the environment served by git daemon on the loopback and the kit
# from this checkout. It changes the machine for good, so it runs only on a
# throwaway one, such as a CI runner, with passwordless sudo.
#
#   DENBOX_TEST_MACHINE=throwaway kit/runtime/tests/host.sh
set -euo pipefail
[[ ${DENBOX_TEST_MACHINE:-} == throwaway ]] ||
  { echo 'host.sh installs Nix and creates a user; set DENBOX_TEST_MACHINE=throwaway on a machine you can lose' >&2; exit 64; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
srv=/srv/denbox-host-test
unit=denbox-test.service
user=boxuser
home=/home/$user
tmp=$(mktemp -d)
cleanup() {
  [[ ! -f $tmp/git-daemon.pid ]] || kill "$(cat "$tmp/git-daemon.pid")" 2> /dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*" >&2
  sudo journalctl -u "$unit" -n 150 --no-pager >&2 || true
  sudo cat "$home/.local/state/denbox/status" >&2 || true
  exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

# as SCRIPT: runs a shell script as the box's user, in a login shell as a
# person would. The script goes on stdin: sudo -i passes a command through
# the login shell with each special character escaped, which turns a
# newline into a line continuation and so joins the lines of a script.
as() { sudo -u "$user" -i bash -euo pipefail <<<"$1"; }
# wait_for SECONDS SCRIPT: until SCRIPT succeeds as the box's user.
wait_for() {
  local deadline=$((SECONDS + $1))
  until as "$2" > /dev/null 2>&1; do
    ((SECONDS < deadline)) || fail "timed out waiting for: $2"
    sleep 5
  done
}
worker_up() { as 'denbox service status worker' | grep -q '^worker: up '; }
commit() { git -C "$srv/environment" add -A && git -C "$srv/environment" -c user.name=test -c user.email=test@example.com commit -qm "$1"; }

# The kit: this checkout's files as they are, tracked or new, readable by
# the box's user. The environment: the fixture with its denbox input on it.
sudo install -d -o "$(id -u)" -g "$(id -g)" -m 0755 "$srv"
mkdir -p "$srv/denbox" "$srv/environment"
git -C "$root" ls-files -z -co --exclude-standard | (cd "$root" && tar --null -T - -cf -) | tar -x -C "$srv/denbox"
chmod -R a+rX "$srv"
sed "s|@KIT@|$srv/denbox|" "$root/kit/runtime/tests/host-fixture/flake.nix" > "$srv/environment/flake.nix"
echo 1 > "$srv/environment/version"
git init -q -b main "$srv/environment" && commit one
# git daemon runs upload-pack as the owner of the repository, which Git
# requires; a file:// URL would have the box's user read another's repository.
git daemon --reuseaddr --export-all --base-path="$srv" --listen=127.0.0.1 --port=9418 \
  --detach --pid-file="$tmp/git-daemon.pid" "$srv"
repository=git://127.0.0.1:9418/environment

echo '# install-host.sh installs Nix and the box for the user the box names'
sudo env DENBOX_SEED="path:$srv/denbox" DENBOX_SYNC_INTERVAL=30 \
  bash "$root/install-host.sh" --repository "$repository" --box test < /dev/null
getent passwd "$user" > /dev/null || fail "no user $user"
[[ $(sudo stat -c '%U:%G %a' /etc/denbox/test/git_token) == "root:$user 640" ]] || fail 'token file permissions'

echo '# the unit is active and the first sync applies the box'
systemctl is-active --quiet "$unit" || fail 'unit not active'
# Until the first sync ends either way; one that fails ends the test at once.
wait_for 1800 'grep -qE " applied |failed exit=" ~/.local/state/denbox/status'
as 'grep -q " applied " ~/.local/state/denbox/status' || fail 'the first sync failed'
[[ $(as 'cat ~/worker-version') == 1 ]] || fail "version $(as 'cat ~/worker-version')"

echo '# its service and the sync loop run under s6, found by the runtime as the user'
wait_for 60 'denbox service status worker | grep -q "^worker: up "'
# The first activation installs the box's own runtime; the sync loop exits
# so that s6 starts it, a few seconds later.
wait_for 60 'denbox service status denbox-sync | grep -q "^denbox-sync: up "'
wait_for 60 'tr "\0" " " < /proc/$(denbox service status denbox-sync | sed -n "s/.*up (pid \([0-9]*\).*/\1/p")/cmdline |
  grep -q "/.nix-profile/bin/denbox sync"'
[[ $(as 'denbox shell -c "id -un"') == "$user" ]] || fail 'denbox shell'

echo '# a new commit is applied'
echo 2 > "$srv/environment/version" && commit two
wait_for 600 '[ "$(cat ~/worker-version)" = 2 ]'

echo '# a commit that fails to build keeps the previous state'
revision=$(as 'cat ~/.local/state/denbox/revision')
touch "$srv/environment/broken" && commit broken
wait_for 600 'grep -q "failed exit=" ~/.local/state/denbox/status'
[[ $(as 'cat ~/.local/state/denbox/revision') == "$revision" ]] || fail 'revision changed'
worker_up || fail 'worker not up'
[[ $(as 'cat ~/worker-version') == 2 ]] || fail 'version changed'

echo '# the box comes back after systemctl restart'
starts=$(as 'wc -l < ~/worker-starts')
sudo systemctl restart "$unit"
wait_for 300 "[ \$(wc -l < ~/worker-starts) -gt $starts ] && denbox service status worker | grep -q '^worker: up '"
systemctl is-active --quiet "$unit" || fail 'unit not active after a restart'

echo '# run again, the installer keeps the home and restarts the box'
as 'echo kept > ~/marker'
starts=$(as 'wc -l < ~/worker-starts')
sudo bash "$root/install-host.sh" --name test < /dev/null
wait_for 300 "[ \$(wc -l < ~/worker-starts) -gt $starts ] && denbox service status worker | grep -q '^worker: up '"
[[ $(as 'cat ~/marker') == kept && $(as 'cat ~/worker-version') == 2 ]] || fail 'the home changed'

echo '# nothing under the home is owned by another user'
owned=$(sudo find "$home" ! -user "$user" -print -quit)
[[ -z $owned ]] || fail "owned by another user: $owned"

echo 'host end-to-end test passed'
