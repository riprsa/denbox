#!/usr/bin/env bash
# shellcheck disable=SC2016 # scripts in single quotes run later, in another shell
# Unit tests of the runtime: real Git and s6, a fake nix. Every path is under
# a temporary directory; nothing touches the machine's own box.
#
#   kit/runtime/tests/unit.sh
#
# Needs bash, git, jq, flock and s6 on PATH.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
denbox=$here/../denbox
tmp=$(mktemp -d)
supervisor=''
# cleanup: stops the supervisor and whatever it started. It asks s6 to stop,
# waits ten seconds at most, then kills every process still working under
# the scan directory, so a failed test cannot keep the run alive.
cleanup() {
  local attempt process
  if [[ -n $supervisor ]]; then
    s6-svscanctl -t "$DENBOX_RUN/services" 2>/dev/null || kill "$supervisor" 2>/dev/null || true
    for ((attempt = 0; attempt < 50; attempt++)); do
      kill -0 "$supervisor" 2>/dev/null || break
      sleep .2
    done
    for process in /proc/[0-9]*; do
      [[ $(readlink "$process/cwd" 2>/dev/null) == "$DENBOX_RUN"/services* ]] || continue
      kill -KILL "${process#/proc/}" 2>/dev/null || true
    done
    wait "$supervisor" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'echo "$0: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

export HOME=$tmp/home USER=test
export DENBOX_STATE=$tmp/state DENBOX_RUN=$tmp/run DENBOX_CONFIG=$HOME/.config/denbox
export DENBOX_BOOTSTRAP=$tmp/bootstrap.json DENBOX_GIT_TOKEN=$tmp/token
export DENBOX_PROFILE_RUNTIME=$tmp/profile-denbox DENBOX_GC_INTERVAL=0 DENBOX_SHELTER=$tmp/shelter
export FAKE=$tmp/fake
unset XDG_STATE_HOME
mkdir -p "$HOME" "$FAKE/bin" "$FAKE/store"

# The fake nix: eval prints the snapshot's follow.json, or for .host the
# snapshot's host.json with the arguments it was called with, build copies the
# snapshot's box/ into a store path named after the snapshot and the
# overrides, and fails when the snapshot has a file named fail or, as Nix
# without a sandbox does, when the home it gives builds exists. flake
# prefetch resolves a reference by $FAKE/revisions.json; a revision
# "cached:REV" is Nix's fallback to a revision seen before. eval --expr pins
# the resolved references as REF?rev=REV. store diff-closures prints one
# line with colour codes.
cat > "$FAKE/bin/nix" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE/calls"
case "$1 ${2:-}" in
  'store gc') exit 0 ;;
  'store diff-closures') printf '\033[1mtool\033[0m: 1.0 \342\206\222 2.0\n'; exit 0 ;;
esac
installable=${*: -1}
case $1 in
  flake)
    rev=$(jq -r --arg ref "$installable" '.[$ref] // empty' "$FAKE/revisions.json" 2>/dev/null || true)
    [[ -n $rev ]] || { echo "error: cannot fetch $installable" >&2; exit 1; }
    if [[ $rev == cached:* ]]; then
      rev=${rev#cached:}
      echo "warning: unable to download $installable; using cached version" >&2
    fi
    jq -n --arg url "$installable" --arg rev "$rev" '{locked: {type: "fake", url: $url, rev: $rev}}' ;;
  eval)
    if [[ $* == *--expr* ]]; then jq -c 'map_values("\(.url)?rev=\(.rev)")' <<<"$DENBOX_LOCKED"; exit 0; fi
    snapshot=${installable#path:}; snapshot=${snapshot%%#*}
    if [[ $installable == *.host ]]; then jq -c --arg args "$*" '. + {args: $args}' "$snapshot/host.json"; exit 0; fi
    cat "$snapshot/follow.json" 2>/dev/null || echo '{}' ;;
  build)
    shift
    link='' overrides=''
    while (($# > 1)); do
      case $1 in
        --out-link) link=$2; shift ;;
        --override-input) overrides+="$2=$3 "; shift 2 ;;
      esac
      shift
    done
    if [[ $installable == /* ]]; then ln -sfn "$installable" "$link"; exit 0; fi
    snapshot=${installable#path:}; snapshot=${snapshot%%#*}
    [[ ! -e $snapshot/fail ]] || { echo 'build failed' >&2; exit 1; }
    [[ ! -e $DENBOX_SHELTER ]] || { echo "error: home directory \"$DENBOX_SHELTER\" exists" >&2; exit 1; }
    # Names and contents, like a store path's hash.
    hash=$( (cd "$snapshot" && find . -type f | sort && find . -type f | sort | xargs cat; echo "$overrides") | sha256sum | cut -c1-16)
    out=$FAKE/store/$hash-box
    [[ -d $out ]] || cp -R "$snapshot/box" "$out"
    ln -sfn "$out" "$link" ;;
  *) exit 64 ;;
esac
SCRIPT
chmod +x "$FAKE/bin/nix"
export PATH=$FAKE/bin:$PATH

# The environment: box/activate links box/services/* into the services
# directory and installs box/runtime as the profile's runtime when present.
repository=$tmp/environment
mkdir -p "$repository/box/services/worker"
cat > "$repository/box/activate" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
box=$(dirname "$(readlink -f "$0")")
echo activate >> "$FAKE/activations"
[[ ! -e $box/activate-fail ]] || exit 19
rm -rf "$DENBOX_CONFIG/services"
mkdir -p "$DENBOX_CONFIG/services"
# Like the store: a service's path changes only with its content.
for service in "$box"/services/*; do
  path=$FAKE/store/$(cat "$service"/* | sha256sum | cut -c1-16)-${service##*/}
  [[ -d $path ]] || cp -R "$service" "$path"
  ln -s "$path" "$DENBOX_CONFIG/services/${service##*/}"
done
[[ ! -e $box/runtime ]] || ln -sfn "$box/runtime" "$DENBOX_PROFILE_RUNTIME"
SCRIPT
cat > "$repository/box/services/worker/run" <<'SCRIPT'
#!/usr/bin/env bash
echo worker-stderr-marker >&2
echo start >> "$FAKE/worker-starts"
exec sleep 600
SCRIPT
chmod +x "$repository/box/activate" "$repository/box/services/worker/run"
git -C "$repository" init -q -b main
commit() {
  git -C "$repository" add -A
  git -C "$repository" -c user.name=test -c user.email=test@example.com commit -qm "$1"
}
commit fixture

write_bootstrap() {
  jq -n --arg repository "$1" '{version: 2, repository: $repository, ref: "main", box: "test",
    sync_interval: 30, apply_timeout: 60, git_username: "oauth2"}' > "$DENBOX_BOOTSTRAP"
}
write_bootstrap "file://$repository"
printf 'test-token\n' > "$DENBOX_GIT_TOKEN"
# The user's Git configuration would send the fetch nowhere; sync must ignore it.
git config --file "$HOME/.gitconfig" url."file:///nonexistent/".insteadOf "file://$tmp/"

count() { if [[ -f $1 ]]; then wc -l < "$1"; else echo 0; fi; }
builds() { grep -c '^build .*path:' "$FAKE/calls" || true; }
evaluations() { grep -c '^eval .*path:' "$FAKE/calls" || true; }
# fail MESSAGE: ends the run, showing what the supervisor and its services
# were doing, which is what a failure that comes and goes needs.
fail() {
  echo "FAIL: $*" >&2
  {
    echo '--- services'
    timeout 10 "$denbox" service status || true
    echo '--- supervisor'
    tail -n 30 "$tmp/supervise.log" || true
    echo '--- sync loop'
    tail -n 20 "$DENBOX_STATE/logs/denbox-sync/current" || true
  } >&2 2>&1
  exit 1
}
wait_for() {
  for ((attempt = 0; attempt < 100; attempt++)); do
    if eval "$1"; then return 0; fi
    sleep .2
  done
  fail "timed out waiting for: $1"
}

echo '# askpass answers with the username and the token without its line end'
[[ $(DENBOX_GIT_USERNAME=me "$here/../askpass" 'Username for https://example.com') == me ]] || fail username
[[ $("$here/../askpass" 'Password for https://example.com') == test-token ]] || fail password

echo '# a first sync builds, activates and records the revision'
"$denbox" sync --once
[[ $(count "$FAKE/activations") == 1 ]] || fail 'not activated once'
[[ $(cat "$DENBOX_STATE/revision") == $(git -C "$repository" rev-parse HEAD) ]] || fail revision
grep -q ' applied ' "$DENBOX_STATE/status" || fail status
[[ ! -e $DENBOX_STATE/snapshots/$(cat "$DENBOX_STATE/revision")/.git ]] || fail 'snapshot has .git'
[[ -x $DENBOX_CONFIG/services/worker/run ]] || fail 'services not installed'

echo '# an unchanged revision neither builds nor activates'
before=$(builds)
"$denbox" sync --once
[[ $(builds) == "$before" && $(count "$FAKE/activations") == 1 ]] || fail 'unchanged revision was applied'

echo '# a new commit is applied and the old snapshot removed'
old=$(cat "$DENBOX_STATE/revision")
echo two > "$repository/box/version"
commit two
"$denbox" sync --once
[[ $(count "$FAKE/activations") == 2 && $(cat "$DENBOX_STATE/revision") != "$old" ]] || fail 'new commit not applied'
[[ ! -e $DENBOX_STATE/snapshots/$old ]] || fail 'old snapshot kept'

echo '# the home an earlier build left behind is removed before the next build'
mkdir -p "$DENBOX_SHELTER/.config"
echo left > "$repository/box/version"
commit 'after a build that wrote to its home'
"$denbox" sync --once
[[ ! -e $DENBOX_SHELTER && $(count "$FAKE/activations") == 3 ]] || fail 'the build home stopped the sync'

echo '# the evaluation and the build add the kit cache; DENBOX_BINARY_CACHE=0 leaves it out'
cache_pattern=' --extra-substituters https://denbox\.cachix\.org --extra-trusted-public-keys denbox\.cachix\.org-1:[A-Za-z0-9+/]+=* '
for call in eval build; do
  grep "^$call .*path:" "$FAKE/calls" | tail -1 | grep -E -- "$cache_pattern" > /dev/null || fail "$call without the cache"
done
echo three > "$repository/box/version"
commit three
DENBOX_BINARY_CACHE=0 "$denbox" sync --once
for call in eval build; do
  ! grep "^$call .*path:" "$FAKE/calls" | tail -1 | grep -q -- '--extra-substituters\|--extra-trusted-public-keys' ||
    fail "$call with the cache switched off"
done

echo '# a failed build keeps the applied box'
applied=$(readlink -f "$DENBOX_STATE/applied")
revision=$(cat "$DENBOX_STATE/revision")
touch "$repository/fail"
commit broken
if "$denbox" sync --once 2>/dev/null; then fail 'failed build reported success'; fi
[[ $(readlink -f "$DENBOX_STATE/applied") == "$applied" && $(cat "$DENBOX_STATE/revision") == "$revision" ]] || fail 'state changed'
grep -q 'failed exit=' "$DENBOX_STATE/status" || fail 'status not failed'

echo '# a failed activation keeps the applied box too'
git -C "$repository" rm -q fail
touch "$repository/box/activate-fail"
commit 'activation fails'
if "$denbox" sync --once 2>/dev/null; then fail 'failed activation reported success'; fi
[[ $(readlink -f "$DENBOX_STATE/applied") == "$applied" && $(cat "$DENBOX_STATE/revision") == "$revision" ]] || fail 'state changed'
git -C "$repository" rm -q box/activate-fail
commit 'activation works'

echo '# one reconciler: a second sync exits 75 while the lock is held'
result=0
flock "$DENBOX_RUN/sync.lock" "$denbox" sync --once 2>/dev/null || result=$?
[[ $result == 75 ]] || fail "expected 75, got $result"
# A sync that failed does not leave the lock behind.
flock -n "$DENBOX_RUN/sync.lock" true || fail 'lock held'

echo '# a broken bootstrap leaves the last valid one in use'
echo '{"version": 2}' > "$DENBOX_BOOTSTRAP"
"$denbox" sync --once 2>"$tmp/err"
grep -q 'not valid' "$tmp/err" || fail 'no warning'
write_bootstrap "file://$repository"

echo '# a box that asks for approval is applied without it the first time, since the mode in force is the applied one'
mkdir -p "$repository/box/home-files/.config/denbox"
echo approve > "$repository/box/home-files/.config/denbox/apply"
commit 'ask for approval'
activations=$(count "$FAKE/activations")
"$denbox" sync --once
[[ $(count "$FAKE/activations") == $((activations + 1)) && -z $("$denbox" pending) ]] || fail 'the switch to approval waited'

echo '# then a new commit is built and left pending, and the box stays as it was'
applied=$(readlink -f "$DENBOX_STATE/applied") revision=$(cat "$DENBOX_STATE/revision")
echo four > "$repository/box/version"
commit four
four=$(git -C "$repository" rev-parse HEAD)
"$denbox" sync --once
[[ $(count "$FAKE/activations") == $((activations + 1)) && $(readlink -f "$DENBOX_STATE/applied") == "$applied" &&
   $(cat "$DENBOX_STATE/revision") == "$revision" ]] || fail 'a pending box was applied'
grep -q " pending $four\$" "$DENBOX_STATE/status" || fail "status: $(cat "$DENBOX_STATE/status")"
"$denbox" pending | jq -e --arg revision "$four" --arg applied "$revision" '
  .revision == $revision and .applied == $applied and .box == "test" and .subject == "four" and
  .apply == "approve" and .changes == ["tool: 1.0 → 2.0"] and (.store | endswith("-box"))' > /dev/null ||
  fail "pending: $("$denbox" pending)"

echo '# a pending box is not built again, and its follow is not evaluated again'
before=$(builds) evaluated=$(evaluations)
"$denbox" sync --once
[[ $(builds) == "$before" && $(evaluations) == "$evaluated" ]] || fail 'a pending box was built or evaluated again'

echo '# apply refuses another revision than the pending one'
result=0
"$denbox" apply "$revision" 2>"$tmp/err" || result=$?
[[ $result == 65 ]] || fail "apply of another revision exited $result"
grep -q "$four waits for approval" "$tmp/err" || fail "apply of another revision: $(cat "$tmp/err")"
[[ $(count "$FAKE/activations") == $((activations + 1)) ]] || fail 'a refused apply activated'

echo '# a newer commit replaces the pending one, and apply activates it'
echo five > "$repository/box/version"
commit five
five=$(git -C "$repository" rev-parse HEAD)
"$denbox" sync --once
[[ $("$denbox" pending | jq -r .revision) == "$five" ]] || fail 'the newer commit is not the pending one'
# As under a running sync loop, which holds its own lock between passes.
flock "$DENBOX_RUN/sync.lock" "$denbox" apply "$five"
[[ $(count "$FAKE/activations") == $((activations + 2)) && $(cat "$DENBOX_STATE/revision") == "$five" &&
   -z $("$denbox" pending) && ! -e $DENBOX_STATE/candidate ]] || fail 'apply did not activate the pending box'
grep -q " applied $five\$" "$DENBOX_STATE/status" || fail "status after apply: $(cat "$DENBOX_STATE/status")"
[[ ! -e $DENBOX_STATE/snapshots/$four ]] || fail 'old snapshot kept after apply'
before=$(builds)
"$denbox" sync --once
[[ $(builds) == "$before" && $(count "$FAKE/activations") == $((activations + 2)) ]] || fail 'an applied box was built again'

echo '# apply with nothing pending does nothing; with a revision it fails'
"$denbox" apply 2>"$tmp/err"
grep -q 'Nothing waits' "$tmp/err" || fail 'no message'
if "$denbox" apply "$five" 2>/dev/null; then fail 'apply of a revision with nothing pending succeeded'; fi

echo '# a branch that goes back to the applied revision leaves nothing pending'
echo six > "$repository/box/version"
commit six
"$denbox" sync --once
[[ -n $("$denbox" pending) ]] || fail 'six is not pending'
git -C "$repository" reset -q --hard "$five"
"$denbox" sync --once
[[ -z $("$denbox" pending) && ! -e $DENBOX_STATE/candidate ]] || fail 'a withdrawn revision is still pending'

echo '# a revision that switches approval off waits for approval itself; the next one does not'
git -C "$repository" rm -rq box/home-files
commit 'approval off'
"$denbox" sync --once
[[ $("$denbox" pending | jq -r .apply) == auto ]] || fail "the switch back was not left pending: $("$denbox" pending)"
"$denbox" apply
activations=$(count "$FAKE/activations")
echo seven > "$repository/box/version"
commit seven
"$denbox" sync --once
[[ $(count "$FAKE/activations") == $((activations + 1)) && -z $("$denbox" pending) ]] || fail 'auto again did not apply'

echo '# followed references are resolved first and built pinned; unchanged revisions skip the build'
echo '{"denbox": "github:example/denbox", "denbox/nixpkgs": "github:example/nixpkgs"}' > "$repository/follow.json"
commit follow
echo '{"github:example/denbox": "r1", "github:example/nixpkgs": "n1"}' > "$FAKE/revisions.json"
activations=$(count "$FAKE/activations")
"$denbox" sync --once
grep '^build .*path:' "$FAKE/calls" | tail -1 |
  grep -- ' --override-input denbox github:example/denbox?rev=r1 --override-input denbox/nixpkgs github:example/nixpkgs?rev=n1 ' > /dev/null ||
  fail "overrides: $(tail -1 "$FAKE/calls")"
! grep -q -- '--refresh .*path:' "$FAKE/calls" || fail 'the build refreshes'
[[ $(count "$FAKE/activations") == $((activations + 1)) ]] || fail 'follow commit not activated'
before=$(builds) evaluated=$(evaluations)
"$denbox" sync --once
[[ $(builds) == "$before" && $(count "$FAKE/activations") == $((activations + 1)) ]] || fail 'unchanged revisions were built'
[[ $(evaluations) == "$evaluated" ]] || fail 'an idle sync evaluated the environment'

echo '# a changed followed revision is built and activated'
echo '{"github:example/denbox": "r2", "github:example/nixpkgs": "n1"}' > "$FAKE/revisions.json"
"$denbox" sync --once
[[ $(builds) == $((before + 1)) && $(count "$FAKE/activations") == $((activations + 2)) ]] || fail 'changed revision not applied'
grep '^build .*path:' "$FAKE/calls" | tail -1 | grep -q 'github:example/denbox?rev=r2 ' || fail 'not built at r2'

echo '# a reference that cannot be resolved fails the sync and keeps the state'
applied=$(readlink -f "$DENBOX_STATE/applied") fingerprint=$(cat "$DENBOX_STATE/fingerprint") before=$(builds)
for revisions in '{"github:example/nixpkgs": "n1"}' '{"github:example/denbox": "cached:r2", "github:example/nixpkgs": "n1"}'; do
  echo "$revisions" > "$FAKE/revisions.json"
  if "$denbox" sync --once 2>"$tmp/err"; then fail "unresolvable reference reported success: $revisions"; fi
  grep -q 'Could not resolve github:example/denbox' "$tmp/err" || fail "no error: $(cat "$tmp/err")"
  [[ $(readlink -f "$DENBOX_STATE/applied") == "$applied" && $(cat "$DENBOX_STATE/fingerprint") == "$fingerprint" &&
     $(builds) == "$before" ]] || fail "state changed: $revisions"
done
echo '{"github:example/denbox": "r2", "github:example/nixpkgs": "n1"}' > "$FAKE/revisions.json"
"$denbox" sync --once
[[ $(builds) == "$before" ]] || fail 'a resolvable reference again was built'

echo '# host prints the declaration evaluated against the followed revisions, in a state of its own'
echo '{"memory": "4g"}' > "$repository/host.json"
commit host
before=$(builds)
host=$(DENBOX_STATE=$tmp/host-state "$denbox" host)
jq -e '.memory == "4g"' <<<"$host" > /dev/null || fail "host: $host"
jq -r .args <<<"$host" | grep -q -- '--override-input denbox github:example/denbox?rev=r2 .*#boxes.test.host$' ||
  fail "host not evaluated pinned: $host"
[[ $(builds) == "$before" && ! -e $tmp/host-state/applied ]] || fail 'host built or applied'
git -C "$repository" rm -q host.json
git -C "$repository" rm -q follow.json
commit 'follow nothing'

echo '# the sync loop exits when an activation changed the runtime'
printf '#!/bin/sh\n' > "$repository/box/runtime"
chmod +x "$repository/box/runtime"
commit runtime
timeout 20 "$denbox" sync > "$tmp/loop" || fail 'loop did not exit 0'
grep -q 'runtime changed' "$tmp/loop" || fail 'loop exited for another reason'
git -C "$repository" rm -q box/runtime
commit 'no runtime'
rm -f "$DENBOX_PROFILE_RUNTIME"

echo '# supervise runs the services and the sync loop under s6'
"$denbox" supervise > "$tmp/supervise.log" 2>&1 &
supervisor=$!
wait_for '"$denbox" service status worker 2>/dev/null | grep "^worker: up " > /dev/null'
"$denbox" service status | grep '^denbox-sync: up ' > /dev/null || fail "sync loop not supervised: $("$denbox" service status; cat "$tmp/supervise.log")"
wait_for '"$denbox" service logs worker -n 5 | grep worker-stderr-marker > /dev/null'
(( (0$(stat -c %a "$DENBOX_STATE/logs/worker") & 077) == 0 )) || fail "log directory is readable by others"
# The format denbox-api parses (newer s6 adds the pgid after the pid).
"$denbox" service status worker | grep -E '^worker: up .*[0-9]+ seconds' > /dev/null || fail 'status format'

echo '# an unchanged service is not restarted; a changed one is; a removed one stops'
"$denbox" service stop denbox-sync
starts=$(count "$FAKE/worker-starts")
mkdir -p "$repository/box/services/other"
printf '#!/bin/sh\nexec sleep 600\n' > "$repository/box/services/other/run"
chmod +x "$repository/box/services/other/run"
commit other
"$denbox" sync --once
wait_for '"$denbox" service status other 2>/dev/null | grep "^other: up " > /dev/null'
[[ $(count "$FAKE/worker-starts") == "$starts" ]] || fail 'unchanged worker restarted'
echo changed >> "$repository/box/services/worker/run"
commit 'worker changes'
"$denbox" sync --once
wait_for '[[ $(count "$FAKE/worker-starts") == $((starts + 1)) ]]'
git -C "$repository" rm -rq box/services/other
commit 'other goes'
"$denbox" sync --once
[[ ! -e $DENBOX_RUN/services/other ]] || fail 'removed service still supervised'
wait_for '! pgrep -f "s6-supervise other" > /dev/null'

echo '# service reconcile applies the services directory now, quietly'
mkdir -p "$tmp/added"
printf '#!/bin/sh\nexec sleep 600\n' > "$tmp/added/run"
chmod +x "$tmp/added/run"
ln -s "$tmp/added" "$DENBOX_CONFIG/services/added"
starts=$(count "$FAKE/worker-starts")
[[ -z $("$denbox" service reconcile 2>&1) ]] || fail 'reconcile printed something'
wait_for '"$denbox" service status added 2>/dev/null | grep "^added: up " > /dev/null'
[[ -z $("$denbox" service reconcile 2>&1) ]] || fail 'an unchanged reconcile printed something'
rm "$DENBOX_CONFIG/services/added"
"$denbox" service reconcile
[[ ! -e $DENBOX_RUN/services/added && $(count "$FAKE/worker-starts") == "$starts" ]] || fail 'reconcile did not remove only added'
if "$denbox" service reconcile worker 2>/dev/null; then fail 'reconcile took a name'; fi

echo '# start, stop and restart'
"$denbox" service stop worker
"$denbox" service status worker | grep '^worker: down ' > /dev/null || fail 'not stopped'
"$denbox" service start worker
wait_for '"$denbox" service status worker | grep "^worker: up " > /dev/null'
starts=$(count "$FAKE/worker-starts")
"$denbox" service restart worker
wait_for '[[ $(count "$FAKE/worker-starts") == $((starts + 1)) ]]'
if "$denbox" service restart nothing 2>/dev/null; then fail 'unknown service accepted'; fi

echo '# a second supervisor is refused and the first keeps its services'
pid=$("$denbox" service status worker | sed -n 's/.*up (pid \([0-9]*\).*/\1/p')
result=0
timeout 20 "$denbox" supervise 2>/dev/null || result=$?
[[ $result == 75 ]] || fail "a second supervise exited $result"
[[ $("$denbox" service status worker | sed -n 's/.*up (pid \([0-9]*\).*/\1/p') == "$pid" ]] || fail 'the worker was restarted'

echo '# a restart without network comes back from the applied state'
s6-svscanctl -t "$DENBOX_RUN/services"
wait "$supervisor" || true
supervisor=''
rm -rf "$DENBOX_RUN"
write_bootstrap "file://$tmp/unreachable"
starts=$(count "$FAKE/worker-starts")
"$denbox" supervise >> "$tmp/supervise.log" 2>&1 &
supervisor=$!
wait_for '[[ $(count "$FAKE/worker-starts") -gt $starts ]]'
wait_for 'grep -q "failed exit=" "$DENBOX_STATE/status"'
"$denbox" service status worker | grep '^worker: up ' > /dev/null || fail 'worker not up'

echo '# shell runs the configured shell, bash without it'
[[ $("$denbox" shell -c 'echo $0') == bash ]] || fail 'no bash fallback'
printf '#!/bin/sh\necho configured "$@"\n' > "$DENBOX_CONFIG/shell"
chmod +x "$DENBOX_CONFIG/shell"
[[ $("$denbox" shell -l) == 'configured -l' ]] || fail 'configured shell not used'

echo 'all runtime tests passed'
