#!/usr/bin/env bash
# Golden-file tests of deploy/render. For every render/CASE.json it renders
# the box `personal` as Compose, Quadlet and an explanation and compares
# them with CASE.compose.yaml, CASE.quadlet/ and CASE.explain; for every
# render/refused/CASE.json it expects status 65 and the message CASE.err.
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

for input in "$golden"/*.json; do
  case=${input%.json}
  "$render" --format compose "${deployment[@]}" "$input" > "$tmp/compose.yaml"
  check "$case.compose.yaml" "$tmp/compose.yaml"
  "$render" --format quadlet "${deployment[@]}" --output "$tmp/quadlet" "$input"
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

((failed == 0)) || exit 1
echo 'render tests passed'
