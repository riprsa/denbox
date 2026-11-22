#!/usr/bin/env bash
# Installs a box on a Docker host, or updates one installed before. Needs
# bash and Docker with Compose; the deployment comes out of the image.
#
#   bash install.sh [--repository URL] [--ref REF] [--box BOX] [--name NAME]
#                   [--dir DIR] [--image IMAGE] [--token-file FILE]
#
# Each option is also read from a variable: DENBOX_REPOSITORY, DENBOX_REF,
# DENBOX_BOX, DENBOX_NAME, DENBOX_DIR, DENBOX_IMAGE, DENBOX_GIT_TOKEN_FILE,
# and DENBOX_GIT_TOKEN for the token itself. What is missing is asked on the
# terminal; the token only when the repository is not readable without one.
# NAME (default BOX) names the Compose project denbox-NAME and its volumes;
# DIR defaults to ./denbox-NAME. DENBOX_BIND_IP, DENBOX_T3_PORT,
# DENBOX_API_PORT, DENBOX_CPUS, DENBOX_MEMORY and DENBOX_PIDS go to Compose.
#
# Run again with the same DIR or name, or from inside DIR, it updates the
# box: it pulls the image and recreates the container with the settings it
# saved, keeping the volumes. It never deletes a volume.
set -euo pipefail
umask 077

fail() { printf 'denbox install: %s\n' "$*" >&2; exit 1; }
# usage: the comment at the top of this file.
usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0" >&2; exit 64; }

settings=(DENBOX_BIND_IP DENBOX_T3_PORT DENBOX_API_PORT DENBOX_CPUS DENBOX_MEMORY DENBOX_PIDS)
repository=${DENBOX_REPOSITORY:-} ref=${DENBOX_REF:-} box=${DENBOX_BOX:-} name=${DENBOX_NAME:-}
dir=${DENBOX_DIR:-} image=${DENBOX_IMAGE:-} token_file=${DENBOX_GIT_TOKEN_FILE:-}
while (($#)); do
  [[ $# -ge 2 ]] || usage
  case $1 in
    --repository) repository=$2 ;;
    --ref) ref=$2 ;;
    --box) box=$2 ;;
    --name) name=$2 ;;
    --dir) dir=$2 ;;
    --image) image=$2 ;;
    --token-file) token_file=$2 ;;
    *) usage ;;
  esac
  shift 2
done

temporary=$(mktemp -d)
tty_state=''
cleanup() {
  [[ -z $tty_state ]] || stty "$tty_state" < /dev/tty 2> /dev/null || true
  rm -rf "$temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The token goes into a file at once and out of the environment, so neither
# Docker nor Compose ever sees it.
token=$temporary/token
if [[ -n ${DENBOX_GIT_TOKEN:-} ]]; then
  printf '%s\n' "$DENBOX_GIT_TOKEN" > "$token"
elif [[ -n $token_file ]]; then
  [[ -r $token_file ]] || fail "Cannot read the token file $token_file"
  cat "$token_file" > "$token"
fi
unset DENBOX_GIT_TOKEN
token_given=false
[[ ! -f $token ]] || token_given=true

command -v docker > /dev/null || fail 'Docker is not installed'
docker compose version > /dev/null 2>&1 || fail 'Docker Compose is not installed'

# load_saved FILE: the settings an earlier run saved in DIR/.env, for what
# neither an option nor a variable gives.
load_saved() {
  local key value
  while IFS='=' read -r key value; do
    case $key in
      DENBOX_REPOSITORY) repository=${repository:-$value} ;;
      DENBOX_REF) ref=${ref:-$value} ;;
      DENBOX_BOX) box=${box:-$value} ;;
      DENBOX_NAME) name=${name:-$value} ;;
      DENBOX_IMAGE) image=${image:-$value} ;;
      DENBOX_*) [[ " ${settings[*]} " != *" $key "* ]] || printf -v "$key" '%s' "${!key:-$value}" ;;
    esac
  done < "$1"
}

# terminal: whether there is a terminal to ask on.
terminal() { { : < /dev/tty; } 2> /dev/null; }

# ask VARIABLE PROMPT [DEFAULT]: reads a value from the terminal when the
# variable is empty; without a terminal the default holds.
ask() {
  local answer
  [[ -z ${!1} ]] || return 0
  if [[ -n ${3:-} ]] && ! terminal; then printf -v "$1" '%s' "$3"; return 0; fi
  terminal || fail "No terminal to ask on; give $2 up front (see the top of install.sh)"
  read -r -p "$2${3:+ [$3]}: " answer < /dev/tty
  printf -v "$1" '%s' "${answer:-${3:-}}"
}

# ask_token: reads the token from the terminal without echo.
ask_token() {
  local answer
  terminal || fail 'The repository needs a token and there is no terminal to ask on; give DENBOX_GIT_TOKEN or --token-file'
  tty_state=$(stty -g < /dev/tty)
  # Echo goes off before the prompt shows, so a fast paste is not echoed.
  stty -echo < /dev/tty
  IFS= read -r -p 'Git token that can read the repository: ' answer < /dev/tty || fail 'No token given'
  stty "$tty_state" < /dev/tty
  printf '\n' > /dev/tty
  [[ -n $answer ]] || fail 'No token given'
  printf '%s\n' "$answer" > "$token"
}

# Earlier settings are in DIR when it is given, in ./denbox-NAME when a
# name or box is, and in the current directory when it is an installation.
if [[ -z $dir && -n ${name:-$box} ]]; then
  dir=./denbox-${name:-$box}
elif [[ -z $dir && -f .env && -f compose.yaml && -f bootstrap.json ]]; then
  dir=.
fi
if [[ -n $dir && -f $dir/.env ]]; then load_saved "$dir/.env"; fi
ask repository 'Environment repository URL'
ask ref 'Branch' main
ask box 'Box name'
name=${name:-$box}
dir=${dir:-./denbox-$name}
image=${image:-ghcr.io/riprsa/denbox:latest}

[[ $repository =~ ^[A-Za-z0-9+.:/@_~%-]+$ ]] || fail "Not a repository URL: $repository"
# The URL is on command lines and in the bootstrap; a token goes in the token file.
[[ ! $repository =~ ://[^/@]*:[^/@]*@ ]] || fail 'Give the token as the token, not in the repository URL'
[[ $ref =~ ^[A-Za-z0-9._/-]+$ && $ref != -* ]] || fail "Not a branch name: $ref"
[[ $box =~ ^[A-Za-z0-9_-]+$ ]] || fail "Not a box name: $box"
[[ $name =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "Not a name for Compose (lowercase letters, digits, _ and -): $name; give --name"
[[ $image =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] || fail "Not an image reference: $image"
for setting in "${settings[@]}"; do
  [[ ${!setting:-} =~ ^[A-Za-z0-9._:-]*$ ]] || fail "Not a valid $setting"
done
if [[ -e $dir && ! -f $dir/.env ]] && [[ -n $(ls -A "$dir") ]]; then
  fail "$dir exists and holds no installation; choose another --dir"
fi

echo "Pulling $image"
# Without the registry a local image still installs, as it was.
docker pull "$image" || { docker image inspect "$image" > /dev/null 2>&1 &&
  echo "Pulling failed; installing the local $image" >&2; } || fail "No image $image"

# readable: whether the image's Git reads the branch with the token in
# $token (none when the file is empty). The token goes in on standard input.
# 0 when it does, 2 when the branch is missing, other codes otherwise.
readable() {
  docker run --rm -i --name "denbox-$name-check" --entrypoint /bin/bash "$image" -c '
    umask 077
    cat > /tmp/token
    GIT_ASKPASS=/nix/var/nix/gcroots/denbox-seed/libexec/denbox/askpass DENBOX_GIT_TOKEN=/tmp/token \
      GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      git ls-remote --exit-code "$1" "refs/heads/$2" > /dev/null' check "$repository" "$ref" < "$token"
}
if [[ $token_given == false ]]; then
  if [[ -f $dir/git_token ]]; then cp "$dir/git_token" "$token"; else : > "$token"; fi
  status=0
  readable 2> /dev/null || status=$?
  if ((status == 2)); then fail "$repository has no branch $ref"; fi
  if ((status != 0)); then ask_token; token_given=true; fi
fi
if [[ $token_given == true ]]; then
  status=0
  readable || status=$?
  if ((status == 2)); then fail "$repository has no branch $ref"; fi
  ((status == 0)) || fail "Cannot read $repository with that token"
fi

# The installation: the deployment from the image, the bootstrap and the
# token as its two secrets, and the settings for Compose and for the next run.
docker run --rm --name "denbox-$name-compose" --entrypoint cat "$image" /usr/local/share/denbox/compose.yaml \
  > "$temporary/compose.yaml"
printf '{"version": 2, "repository": "%s", "ref": "%s", "box": "%s"}\n' "$repository" "$ref" "$box" \
  > "$temporary/bootstrap.json"
{
  printf '%s=%s\n' DENBOX_NAME "$name" DENBOX_IMAGE "$image" DENBOX_REPOSITORY "$repository" \
    DENBOX_REF "$ref" DENBOX_BOX "$box" DENBOX_BOOTSTRAP_FILE ./bootstrap.json DENBOX_GIT_TOKEN_FILE ./git_token
  for setting in "${settings[@]}"; do
    [[ -z ${!setting:-} ]] || printf '%s=%s\n' "$setting" "${!setting}"
  done
} > "$temporary/.env"
mkdir -p "$dir"
chmod 0700 "$dir"
dir=$(cd "$dir" && pwd -P)
for file in compose.yaml bootstrap.json .env; do mv -f "$temporary/$file" "$dir/$file"; done
mv -f "$token" "$dir/git_token"
chmod 0600 "$dir/bootstrap.json" "$dir/git_token" "$dir/.env"
chmod 0644 "$dir/compose.yaml"

for volume in "denbox-$name-home" "denbox-$name-nix"; do
  docker volume inspect "$volume" > /dev/null 2>&1 || docker volume create "$volume" > /dev/null
done

# Compose reads only the saved settings, not this shell's.
unset "${!DENBOX_@}" COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES
docker compose --project-directory "$dir" -f "$dir/compose.yaml" up -d --force-recreate --pull never

cat <<EOF

The box denbox-$name is starting; its first build takes a while.
Installation: $dir (run install.sh again with --dir $dir to update)
Logs:  cd $dir && docker compose logs -f box
Shell: cd $dir && docker compose exec box denbox shell
EOF
