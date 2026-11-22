#!/usr/bin/env bash
# Golden-file tests of deploy/render. For every render/CASE.json it renders
# the box `personal` as Compose, Quadlet and an explanation and compares
# them with CASE.compose.yaml, CASE.quadlet/ and CASE.explain; for every
# render/refused/CASE.json it expects status 65 and the message CASE.err.
# Each declared secret NAME is given as ./secrets/NAME; a missing or an
# undeclared --secret is refused with status 64.
#
#   deploy/tests/render.sh            compare
#   UPDATE=1 deploy/tests/render.sh   write the golden files anew
#
# The flake check `host` runs it, and renders the template's box against
# render/default.json.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
render=$here/../render
golden=$here/render
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

# check GOLDEN ACTUAL: compares, or copies under UPDATE.
check() {
  if [[ -n ${UPDATE:-} ]]; then rm -rf "$1"; cp -R "$2" "$1"; return; fi
  diff -ru "$1" "$2" || { echo "FAIL: $1" >&2; failed=1; }
}
deployment=(--name personal --image ghcr.io/riprsa/denbox:latest --bootstrap ./bootstrap.json --token ./git_token)

# given JSON: the --secret options for every secret the declaration names.
given() { jq -r '.secrets | keys[] | "--secret", "\(.)=./secrets/\(.)"' "$1"; }

for input in "$golden"/*.json; do
  case=${input%.json}
  mapfile -t secrets < <(given "$input")
  "$render" --format compose "${deployment[@]}" "${secrets[@]}" "$input" > "$tmp/compose.yaml"
  check "$case.compose.yaml" "$tmp/compose.yaml"
  "$render" --format quadlet "${deployment[@]}" "${secrets[@]}" --output "$tmp/quadlet" "$input"
  check "$case.quadlet" "$tmp/quadlet"
  "$render" --explain --name personal < "$input" > "$tmp/explain"
  check "$case.explain" "$tmp/explain"
  rm -r "$tmp/quadlet"
done

for input in "$golden"/refused/*.json; do
  status=0
  "$render" --format compose "${deployment[@]}" "$input" > "$tmp/out" 2> "$tmp/err" || status=$?
  [[ $status == 65 && ! -s $tmp/out ]] || { echo "FAIL: $input: status $status" >&2; failed=1; }
  check "${input%.json}.err" "$tmp/err"
done

# expect_usage MESSAGE ARGS: status 64 with MESSAGE and nothing rendered.
expect_usage() {
  local message=$1 status=0
  shift
  "$render" --format compose "${deployment[@]}" "$@" > "$tmp/out" 2> "$tmp/err" || status=$?
  if [[ $status != 64 || -s $tmp/out ]] || ! grep -qF -e "$message" "$tmp/err"; then
    echo "FAIL: $*: status $status, $(cat "$tmp/err")" >&2
    failed=1
  fi
}
expect_usage 'no --secret for the declared secret key' --secret token=./t "$golden/asks.json"
expect_usage '--secret other names no declared secret' --secret other=./o "$golden/default.json"
expect_usage "Not a path this script can write without quoting: './;x'" --secret 'other=./;x' "$golden/default.json"

((failed == 0)) || exit 1
echo 'render tests passed'
