#!/usr/bin/env bash
# shellcheck disable=SC2016 # scripts in single quotes run later, in another shell
# End-to-end test of a box in a tailnet, without a real one: Headscale as the
# control server, a box of the image and a plain Tailscale client, on a
# private Docker network. The box is built from kit/runtime/tests/tailnet,
# whose denbox input is this checkout, and started with Compose from what
# deploy/render makes of the box's own denbox.host, evaluated with this
# machine's Nix: the device, the capability and the key are what the module
# declares, not flags of this test. An overlay adds only what the test
# needs: the private network, the relay setting and shared volumes.
#
#   kit/runtime/tests/tailscale.sh IMAGE
#
# Needs Nix, Docker with Compose and jq. Creates the network, containers and
# volumes denbox-test-tailnet-$$-*, at most three containers at a time, and
# removes them by name when done. DENBOX_TEST_MEMORY sets the memory limit
# of the control server and the client (default 2g); the box has its own.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: tailscale.sh IMAGE' >&2; exit 64; }
image=$1
headscale_image=headscale/headscale:0.29.7@sha256:11f81665e842809db9fe3006a38c56a66e968baa5abd4bac498e86445572b970
tailscale_image=tailscale/tailscale:v1.104.4@sha256:ed6480b33c6eb67c9cbd203ed42b9fb57e361986725b6856def71b7a3d9e276c
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
prefix=denbox-test-tailnet-$$
network=$prefix
control=$prefix-headscale
client=$prefix-client
box=$prefix-box
store=$prefix-nix
limits=(--memory "${DENBOX_TEST_MEMORY:-2g}" --cpus 2 --pids-limit 2048)
tmp=$(mktemp -d)
deploy=$tmp/deploy
cleanup() {
  docker rm -fv "$box" "$client" "$control" > /dev/null 2>&1 || true
  docker volume rm "$prefix-home-kernel" "$prefix-home-userspace" "$store" > /dev/null 2>&1 || true
  docker network rm "$network" > /dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*" >&2
  docker exec "$box" sh -c 'cd /root/.local/state/denbox && cat status; denbox service status
    for log in logs/*/current; do echo "== $log"; tail -n 40 "$log"; done' >&2 ||
    docker logs --tail 80 "$box" >&2 || true
  docker logs --tail 20 "$control" >&2 || true
  exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

# run_in CONTAINER SCRIPT: runs a shell script in a container.
run_in() { docker exec "$1" sh -euc "$2"; }
# wait_for SECONDS CONTAINER SCRIPT: until SCRIPT succeeds in CONTAINER.
wait_for() {
  local deadline=$((SECONDS + $1))
  until run_in "$2" "$3" > /dev/null 2>&1; do
    ((SECONDS < deadline)) || fail "timed out waiting in $2 for: $3"
    sleep 3
  done
}
headscale() { docker exec "$control" headscale "$@"; }
# key: a pre-authenticated key for one node, used once.
key() { headscale preauthkeys create -u 1 -e 1h -o json | jq -r .key; }
# node NAME: the control server's record of the node NAME.
node() { headscale nodes list -o json | jq -c --arg name "$1" '[.[] | select(.given_name == $name)]'; }
ip_of() { headscale nodes list -o json | jq -r --arg name "$1" '.[] | select(.given_name == $name) | .ip_addresses[0]'; }
# fetch NODE PORT: what the client gets from what NODE serves on PORT, by
# address. Serve answers by the node's name, so the request carries it.
fetch() {
  docker exec "$client" wget -qO- -T 5 --header "Host: $1.tailnet.example.com:$2" "http://$(ip_of "$1"):$2/"
}

# declared NAME: what the environment's box NAME asks of its host.
declared() {
  nix eval --json --no-write-lock-file --override-input denbox "path:$tmp/srv/denbox" \
    "path:$tmp/srv/environment#boxes.$1.host"
}

# start_box NAME HOME KEY [JQ]: the environment's box NAME as the container
# $box, deployed from its declaration (changed by the jq program JQ, when
# given), with KEY as its tailscale_authkey secret and HOME as its home.
start_box() {
  local name=$1 home=$2 key=$3 change=${4:-.}
  rm -rf "$deploy"
  mkdir -p "$deploy"
  jq -n --arg box "$name" '{version: 2, repository: "file:///srv/environment", ref: "main", box: $box,
    sync_interval: 3600, apply_timeout: 3600}' > "$deploy/bootstrap.json"
  : > "$deploy/git_token"
  printf '%s\n' "$key" > "$deploy/tailscale_authkey"
  declared "$name" | jq "$change" > "$deploy/host.json"
  "$root/deploy/render" --format compose --name "${box#denbox-}" --image "$image" --bootstrap ./bootstrap.json \
    --token ./git_token --secret tailscale_authkey=./tailscale_authkey "$deploy/host.json" > "$deploy/compose.yaml"
  # What only this test needs. TS_DEBUG_USE_DERP_HTTP: see the relay below.
  jq -n --arg network "$network" --arg home "$home" --arg store "$store" '{
    services: {box: {networks: ["tailnet"], environment: {TS_DEBUG_USE_DERP_HTTP: "1"}}},
    networks: {tailnet: {name: $network, external: true}},
    volumes: {home: {name: $home}, nix: {name: $store}}}' > "$deploy/test.yaml"
  docker volume create "$home" > /dev/null
  docker compose --project-directory "$deploy" -f "$deploy/compose.yaml" -f "$deploy/test.yaml" create --pull never \
    > /dev/null
  # As root's files: Git refuses a repository that another user owns.
  tar -C "$tmp/srv" --owner=0 --group=0 -c . | docker cp - "$box:/srv"
  docker start "$box" > /dev/null
}

# The kit as this checkout has it, and the environment with two boxes.
mkdir -p "$tmp/srv/denbox" "$tmp/srv/environment" "$tmp/etc/headscale"
git -C "$root" ls-files -z -co --exclude-standard | (cd "$root" && tar --null -T - -cf -) | tar -x -C "$tmp/srv/denbox"
cp "$root/kit/runtime/tests/tailnet/flake.nix" "$tmp/srv/environment/"
git init -q -b main "$tmp/srv/environment"
git -C "$tmp/srv/environment" add -A
git -C "$tmp/srv/environment" -c user.name=test -c user.email=test@example.com commit -qm environment

# Headscale with its own relay (DERP), on the same plain-HTTP port. Nodes
# find their direct path through a relay, and Tailscale speaks DERP over
# HTTP only with TS_DEBUG_USE_DERP_HTTP, which each container of the test
# sets for its tailscaled. The box's module knows nothing of it.
cat > "$tmp/etc/headscale/config.yaml" <<'EOF'
server_url: http://headscale:8080
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
derp:
  server:
    enabled: true
    region_id: 999
    region_code: test
    region_name: Test
    stun_listen_addr: 0.0.0.0:3478
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
  urls: []
  paths: []
  auto_update_enabled: false
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
dns:
  magic_dns: true
  base_domain: tailnet.example.com
  override_local_dns: false
EOF
relay=(-e TS_DEBUG_USE_DERP_HTTP=1)

echo '# the control server and a client'
docker network create "$network" > /dev/null
docker volume create "$store" > /dev/null
docker create --name "$control" "${limits[@]}" --network "$network" --network-alias headscale \
  "$headscale_image" serve > /dev/null
tar -C "$tmp" --owner=0 --group=0 -c etc | docker cp - "$control:/"
docker start "$control" > /dev/null
for ((attempt = 0; attempt < 30; attempt++)); do headscale users create test > /dev/null 2>&1 && break; sleep 1; done
docker run -d --rm --name "$client" "${limits[@]}" --network "$network" --cap-add NET_ADMIN --device /dev/net/tun \
  -e TS_AUTHKEY="$(key)" -e TS_USERSPACE=false -e TS_HOSTNAME=client -e TS_STATE_DIR=/var/lib/tailscale \
  -e TS_EXTRA_ARGS=--login-server=http://headscale:8080 "${relay[@]}" "$tailscale_image" > /dev/null
wait_for 60 "$client" 'tailscale status --json | grep -q "\"BackendState\": \"Running\""'
docker exec "$client" tailscale serve --bg --yes --http=80 text:client > /dev/null
client_ip=$(ip_of client)

echo '# the box asks for the tunnel and the key; in userspace for the key only'
jq -e '.devices == ["/dev/net/tun"] and .capabilities == ["NET_ADMIN"] and
  .secrets.tailscale_authkey.target == "/run/secrets/denbox_tailscale_authkey"' <<<"$(declared kernel)" > /dev/null ||
  fail "kernel declares: $(declared kernel)"
jq -e '.devices == [] and .capabilities == [] and (.secrets | keys) == ["tailscale_authkey"]' \
  <<<"$(declared userspace)" > /dev/null || fail "userspace declares: $(declared userspace)"

echo '# deployed without the device and the capability the service says why and stays down'
start_box kernel "$prefix-home-kernel" "$(key)" '.devices = [] | .capabilities = []'
wait_for 3600 "$box" 'grep -q " applied " /root/.local/state/denbox/status'
wait_for 60 "$box" 'grep -q "which the box asks for in denbox.host" /root/.local/state/denbox/logs/tailscale/current'
wait_for 30 "$box" 'denbox service status tailscale | grep -q "^tailscale: down"'
docker rm -f "$box" > /dev/null

echo '# deployed as it asks, the box joins with the key under its hostname'
key=$(key)
start_box kernel "$prefix-home-kernel" "$key"
deadline=$((SECONDS + 300))
until [[ $(node box-kernel | jq length) == 1 ]]; do
  ((SECONDS < deadline)) || fail 'the box did not join'
  sleep 3
done
wait_for 120 "$box" 'grep -q "serves 1 entries" /root/.local/state/denbox/logs/tailscale/current'
box_ip=$(ip_of box-kernel)
id=$(node box-kernel | jq -r '.[0].id')

echo '# the key is in no process and no log'
# The key comes in on standard input and goes to grep through a pipe, so
# no command line of the search holds it.
docker exec -i "$box" bash -c 'key=$(cat)
  ! grep -qsFf <(printf "%s\n" "$key") /proc/[0-9]*/cmdline /proc/[0-9]*/environ &&
  ! grep -rqFf <(printf "%s\n" "$key") /root/.local/state/denbox/logs' <<<"$key" || fail 'the key is in a process or a log'
! docker logs "$box" 2>&1 | grep -qF -e "$key" || fail 'the key is in the container log'
! docker inspect "$box" | grep -qF -e "$key" || fail 'the key is in the container configuration'

echo '# a program in the box reaches the client with no proxy, by address and by name'
run_in "$box" '! env | grep -qi proxy'
# The first packets find the direct path; the client serves by its name.
wait_for 60 "$box" "curl -fsS -m 5 -H 'Host: client.tailnet.example.com' http://$client_ip/ | grep -qx client"
docker exec "$box" grep -q '^nameserver 100.100.100.100' /etc/resolv.conf || fail 'resolver not configured'
[[ $(docker exec "$box" curl -fsS -m 10 http://client.tailnet.example.com/) == client ]] || fail 'MagicDNS'
# Names outside the tailnet still resolve, through Docker's resolver.
docker exec "$box" getent hosts headscale > /dev/null || fail 'other names do not resolve'

echo '# the client reaches what the box serves and nothing else'
[[ $(fetch box-kernel 8080) == 'served by the box' ]] || fail 'not served'
! fetch box-kernel 8000 > /dev/null 2>&1 || fail 'the unserved port answers'
docker exec "$box" tailscale serve --bg --yes --http=8081 http://127.0.0.1:8000 > /dev/null
[[ $(fetch box-kernel 8081) == 'served by the box' ]] || fail 'served by hand'
docker exec "$box" denbox service restart tailscale
deadline=$((SECONDS + 120))
until fetch box-kernel 8080 > /dev/null 2>&1 && ! fetch box-kernel 8081 > /dev/null 2>&1; do
  ((SECONDS < deadline)) || fail 'what the box serves is not what its options say'
  sleep 3
done

echo '# after a restart without the key the box is the same node'
: > "$deploy/tailscale_authkey"
docker restart "$box" > /dev/null
wait_for 120 "$box" 'tailscale status --json | grep -q "\"BackendState\": \"Running\""'
[[ $(node box-kernel | jq -r 'map(.id) | join(" ")') == "$id" ]] || fail "another node: $(node box-kernel)"
[[ $(ip_of box-kernel) == "$box_ip" ]] || fail 'another address'
deadline=$((SECONDS + 60))
until fetch box-kernel 8080 > /dev/null 2>&1; do
  ((SECONDS < deadline)) || fail 'not served after the restart'
  sleep 3
done
docker rm -f "$box" > /dev/null

echo '# in userspace, without a device, the box joins, is reachable and reaches out through its proxy'
start_box userspace "$prefix-home-userspace" "$(key)"
deadline=$((SECONDS + 1200))
until [[ $(node userspace | jq length) == 1 ]]; do
  ((SECONDS < deadline)) || fail 'the userspace box did not join'
  sleep 3
done
deadline=$((SECONDS + 120))
until [[ $(fetch userspace 8080 2> /dev/null) == 'served by the box' ]]; do
  ((SECONDS < deadline)) || fail 'the userspace box is not reachable'
  sleep 3
done
# By name: the proxies resolve tailnet names themselves.
[[ $(docker exec "$box" curl -fsS -m 10 --socks5-hostname 127.0.0.1:1055 http://client.tailnet.example.com/) == client ]] ||
  fail 'no SOCKS5 proxy to the client'
[[ $(docker exec "$box" curl -fsS -m 10 --proxy http://127.0.0.1:1055 http://client.tailnet.example.com/) == client ]] ||
  fail 'no HTTP proxy to the client'

echo 'tailscale test passed'
