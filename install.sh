#!/usr/bin/env bash
# shellcheck disable=SC2016 # scripts in single quotes run later, in containers of the image
# Installs a box on a Docker or Podman host, or updates one installed before.
# Needs bash and a container runtime: Docker with Compose, or Podman with
# Quadlet and a user systemd. Everything else runs in containers of the image.
#
#   bash install.sh [--repository URL] [--ref REF] [--box BOX] [--name NAME]
#                   [--dir DIR] [--image IMAGE] [--runtime docker|podman]
#                   [--token-file FILE] [--secret-file NAME=FILE]... [--accept]
#
# Each option is also read from a variable: DENBOX_REPOSITORY, DENBOX_REF,
# DENBOX_BOX, DENBOX_NAME, DENBOX_DIR, DENBOX_IMAGE, DENBOX_RUNTIME,
# DENBOX_GIT_TOKEN_FILE and DENBOX_ACCEPT=1. DENBOX_GIT_TOKEN holds the token
# itself, DENBOX_SECRET_<NAME> a secret, NAME in capitals. What is missing is
# asked on the terminal; the token only when the repository is not readable
# without one.
#
# What the box asks of its host comes from the environment: the installer
# evaluates boxes.BOX.host at REF, shows it in words, and starts the box only
# when a person accepts it, and asks again on an update only when it
# changed. --accept accepts it without asking, which an unattended run needs.
# Each secret the box declares is asked for like the token and kept in
# DIR/secrets.
#
# NAME (default BOX) names the container denbox-NAME and its volumes; DIR
# defaults to ./denbox-NAME. The runtime is Docker when it is installed,
# Podman otherwise. Docker starts DIR/compose.yaml with Compose; Podman
# copies the Quadlet units of DIR/quadlet to ~/.config/containers/systemd
# and starts the user service denbox-NAME.
#
# Run again with the same DIR or name, or from inside DIR, it updates the
# box: it pulls the image and recreates the container with the settings it
# saved, keeping the volumes and the secrets. It never deletes a volume.
set -euo pipefail
umask 077

fail() { printf 'denbox install: %s\n' "$*" >&2; exit 1; }
# usage: the comment at the top of this file.
usage() { sed -n '3,/^[^#]/s/^# \{0,1\}//p' "$0" >&2; exit 64; }

repository=${DENBOX_REPOSITORY:-} ref=${DENBOX_REF:-} box=${DENBOX_BOX:-} name=${DENBOX_NAME:-}
dir=${DENBOX_DIR:-} image=${DENBOX_IMAGE:-} token_file=${DENBOX_GIT_TOKEN_FILE:-}
runtime=${DENBOX_RUNTIME:-} accept=${DENBOX_ACCEPT:-}
secret_files=()
while (($#)); do
  if [[ $1 == --accept ]]; then accept=1; shift; continue; fi
  [[ $# -ge 2 ]] || usage
  case $1 in
    --repository) repository=$2 ;;
    --ref) ref=$2 ;;
    --box) box=$2 ;;
    --name) name=$2 ;;
    --dir) dir=$2 ;;
    --image) image=$2 ;;
    --runtime) runtime=$2 ;;
    --token-file) token_file=$2 ;;
    --secret-file) secret_files+=("$2") ;;
    *) usage ;;
  esac
  shift 2
done
[[ -z $accept || $accept == 1 ]] || fail 'DENBOX_ACCEPT is 1 or empty'

temporary=$(mktemp -d)
tty_state=''
cleanup() {
  [[ -z $tty_state ]] || stty "$tty_state" < /dev/tty 2> /dev/null || true
  rm -rf "$temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The token goes into a file at once and out of the environment, so no
# container runtime ever sees it.
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

# Secrets given up front, the same way, by name. Which ones the box
# declares is known only after the evaluation; a variable beats a file.
given=$temporary/given
mkdir "$given"
for variable in "${!DENBOX_SECRET_@}"; do
  secret=${variable#DENBOX_SECRET_}
  secret=${secret,,}
  [[ $secret =~ ^[a-z][a-z0-9_]*$ ]] || fail "Not a secret name: $variable"
  printf '%s\n' "${!variable}" > "$given/$secret"
  unset "$variable"
done
for entry in "${secret_files[@]}"; do
  secret=${entry%%=*} file=${entry#*=}
  [[ $entry == *=* && $secret =~ ^[a-z][a-z0-9_]*$ ]] || fail "Not NAME=FILE: $entry"
  [[ ! -f $given/$secret ]] || continue
  [[ -r $file ]] || fail "Cannot read the secret file $file"
  cat "$file" > "$given/$secret"
done

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
      DENBOX_RUNTIME) runtime=${runtime:-$value} ;;
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

# read_hidden VARIABLE PROMPT: reads a line from the terminal without echo.
# Echo goes off before the prompt shows, so a fast paste is not echoed.
read_hidden() {
  local line=''
  tty_state=$(stty -g < /dev/tty)
  stty -echo < /dev/tty
  IFS= read -r -p "$2: " line < /dev/tty || true
  stty "$tty_state" < /dev/tty
  tty_state=''
  printf '\n' > /dev/tty
  printf -v "$1" '%s' "$line"
}

# ask_token: reads the Git token from the terminal into $token.
ask_token() {
  local answer
  terminal || fail 'The repository needs a token and there is no terminal to ask on; give DENBOX_GIT_TOKEN or --token-file'
  read_hidden answer 'Git token that can read the repository'
  [[ -n $answer ]] || fail 'No token given'
  printf '%s\n' "$answer" > "$token"
}

# ask_secret NAME ALLOW_EMPTY DESCRIPTION FILE: reads a secret the box
# declares from the terminal into FILE. Without a terminal, one that may be
# empty is empty and any other stops the installer.
ask_secret() {
  local answer='' hint=''
  [[ $2 != true ]] || hint=' (may be empty)'
  if terminal; then
    printf 'The box asks for the secret %s: %s\n' "$1" "$3"
    read_hidden answer "Secret $1$hint"
    [[ -n $answer || $2 == true ]] || fail "No secret $1 given"
  elif [[ $2 != true ]]; then
    fail "The box needs the secret $1 ($3) and there is no terminal to ask on; give DENBOX_SECRET_${1^^} or --secret-file $1=FILE"
  fi
  if [[ -n $answer ]]; then printf '%s\n' "$answer" > "$4"; else : > "$4"; echo "The secret $1 is empty" >&2; fi
}

# changes OLD NEW: the lines of the explanation that went (-) and came (+).
changes() {
  local line
  while IFS= read -r line; do [[ $'\n'$2$'\n' == *$'\n'"$line"$'\n'* ]] || printf -- '- %s\n' "$line"; done <<<"$1"
  while IFS= read -r line; do [[ $'\n'$1$'\n' == *$'\n'"$line"$'\n'* ]] || printf -- '+ %s\n' "$line"; done <<<"$2"
}

# Earlier settings are in DIR when it is given, in ./denbox-NAME when a
# name or box is, and in the current directory when it is an installation.
if [[ -z $dir && -n ${name:-$box} ]]; then
  dir=./denbox-${name:-$box}
elif [[ -z $dir && -f .env && -f bootstrap.json ]]; then
  dir=.
fi
if [[ -n $dir && -f $dir/.env ]]; then load_saved "$dir/.env"; fi
ask repository 'Environment repository URL'
ask ref 'Branch' main
ask box 'Box name'
name=${name:-$box}
dir=${dir:-./denbox-$name}
image=${image:-ghcr.io/riprsa/denbox:latest}
if [[ -z $runtime ]]; then
  if command -v docker > /dev/null; then runtime=docker; else runtime=podman; fi
fi

[[ $repository =~ ^[A-Za-z0-9+.:/@_~%-]+$ ]] || fail "Not a repository URL: $repository"
# The URL is on command lines and in the bootstrap; a token goes in the token file.
[[ ! $repository =~ ://[^/@]*:[^/@]*@ ]] || fail 'Give the token as the token, not in the repository URL'
[[ $ref =~ ^[A-Za-z0-9._/-]+$ && $ref != -* ]] || fail "Not a branch name: $ref"
[[ $box =~ ^[A-Za-z0-9_-]+$ ]] || fail "Not a box name: $box"
[[ $name =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "Not a container name (lowercase letters, digits, _ and -): $name; give --name"
[[ $image =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] || fail "Not an image reference: $image"
case $runtime in
  docker)
    command -v docker > /dev/null || fail 'Docker is not installed'
    docker compose version > /dev/null 2>&1 || fail 'Docker Compose is not installed' ;;
  podman)
    command -v podman > /dev/null || fail 'Neither Docker nor Podman is installed'
    command -v systemctl > /dev/null || fail 'Podman runs the box as a systemd user service, and there is no systemctl' ;;
  *) fail "The runtime is docker or podman, not $runtime" ;;
esac
cli=$runtime
if [[ -e $dir && ! -f $dir/.env ]] && [[ -n $(ls -A "$dir") ]]; then
  fail "$dir exists and holds no installation; choose another --dir"
fi

echo "Pulling $image"
# Without the registry a local image still installs, as it was.
"$cli" pull "$image" || { "$cli" image inspect "$image" > /dev/null 2>&1 &&
  echo "Pulling failed; installing the local $image" >&2; } || fail "No image $image"

# readable: whether the image's Git reads the branch with the token in
# $token (none when the file is empty). The token goes in on standard input.
# 0 when it does, 2 when the branch is missing, other codes otherwise.
readable() {
  "$cli" run --rm -i --name "denbox-$name-check" --entrypoint /bin/bash "$image" -c '
    umask 077
    cat > /tmp/token
    GIT_ASKPASS=/usr/local/share/denbox/runtime/askpass DENBOX_GIT_TOKEN=/tmp/token \
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

printf '{"version": 2, "repository": "%s", "ref": "%s", "box": "%s"}\n' "$repository" "$ref" "$box" \
  > "$temporary/bootstrap.json"

# evaluate: prints boxes.BOX.host, the environment at the ref fetched and
# followed as the box's sync does (`denbox host`). It runs over the box's
# Nix volume, so the box's first build does not fetch again what it fetched.
# The bootstrap and the token go in on standard input.
evaluate() {
  "$cli" volume inspect "denbox-$name-nix" > /dev/null 2>&1 || "$cli" volume create "denbox-$name-nix" > /dev/null
  cat "$temporary/bootstrap.json" "$token" |
    "$cli" run --rm -i --name "denbox-$name-host" -v "denbox-$name-nix:/nix" --entrypoint /bin/bash "$image" -c '
      set -euo pipefail
      umask 077
      work=$(mktemp -d)
      IFS= read -r line
      printf "%s\n" "$line" > "$work/bootstrap.json"
      cat > "$work/token"
      DENBOX_STATE=$work/state DENBOX_BOOTSTRAP=$work/bootstrap.json DENBOX_GIT_TOKEN=$work/token \
        /usr/local/share/denbox/runtime/denbox host'
}
echo "Evaluating what boxes.$box asks of its host; the first time this fetches the environment's inputs"
evaluate > "$temporary/host.json" || fail "Could not evaluate boxes.$box.host"

# in_image SCRIPT [ARGS]: runs a bash script in a throwaway container of the
# image with the box's declaration on standard input; deploy/render is
# /usr/local/share/denbox/render there.
in_image() {
  "$cli" run --rm -i --name "denbox-$name-render" --entrypoint /bin/bash "$image" \
    -c "set -euo pipefail; $1" in_image "${@:2}" < "$temporary/host.json"
}
explanation=$(in_image '/usr/local/share/denbox/render --explain --name "$1"' "$name") ||
  fail 'This installer cannot deploy what the box asks for'

# The request is shown and accepted before anything is written or started,
# and asked for again only when it differs from the one accepted last.
previous=''
[[ ! -f $dir/accepted ]] || previous=$(< "$dir/accepted")
if [[ $explanation == "$previous" ]]; then
  echo "The box asks for what was accepted before."
else
  printf '\n%s\n' "$explanation"
  if [[ -n $previous ]]; then
    printf '\nChanged since it was accepted last:\n'
    changes "$previous" "$explanation"
  fi
  echo
  if [[ -n $accept ]]; then
    echo 'Accepted with --accept.'
  elif terminal; then
    read -r -p 'Start the box with this? [y/N] ' answer < /dev/tty
    [[ $answer == [yY]* ]] || fail 'Not accepted; nothing was started'
  else
    fail 'No terminal to ask whether the box may have this; read it and run again with --accept (DENBOX_ACCEPT=1)'
  fi
fi

# The secrets the box declares: given up front, kept from the last run, or
# asked for.
mkdir "$temporary/secrets"
in_image 'jq -r ".secrets | to_entries[] | [.key, .value.allowEmpty, .value.description] | @tsv"' \
  > "$temporary/secrets.tsv"
declared=()
while IFS=$'\t' read -r secret empty description; do
  declared+=("$secret")
  if [[ -f $given/$secret ]]; then
    mv "$given/$secret" "$temporary/secrets/$secret"
  elif [[ -f $dir/secrets/$secret ]]; then
    cp "$dir/secrets/$secret" "$temporary/secrets/$secret"
  else
    ask_secret "$secret" "$empty" "$description" "$temporary/secrets/$secret"
  fi
  [[ $empty == true || -s $temporary/secrets/$secret ]] || fail "The secret $secret may not be empty"
done < "$temporary/secrets.tsv"
for file in "$given"/*; do
  [[ ! -e $file ]] || fail "The box declares no secret ${file##*/}"
done

# The installation: the bootstrap, the token, the secrets, the request
# accepted, the settings for the next run and the deployment rendered from
# the declaration. Compose reads paths relative to DIR, Quadlet absolute ones.
mkdir -p "$dir"
chmod 0700 "$dir"
dir=$(cd "$dir" && pwd -P)
printf '%s\n' "$explanation" > "$temporary/accepted"
printf '%s=%s\n' DENBOX_NAME "$name" DENBOX_IMAGE "$image" DENBOX_REPOSITORY "$repository" \
  DENBOX_REF "$ref" DENBOX_BOX "$box" DENBOX_RUNTIME "$runtime" > "$temporary/.env"
deployment=(--name "$name" --image "$image")
if [[ $runtime == docker ]]; then
  deployment+=(--bootstrap ./bootstrap.json --token ./git_token)
  for secret in "${declared[@]}"; do deployment+=(--secret "$secret=./secrets/$secret"); done
  in_image '/usr/local/share/denbox/render --format compose "$@"' "${deployment[@]}" > "$temporary/compose.yaml"
else
  [[ $dir =~ ^[A-Za-z0-9._/@+-]+$ ]] || fail "Quadlet units cannot name the directory $dir; choose another --dir"
  deployment+=(--bootstrap "$dir/bootstrap.json" --token "$dir/git_token")
  for secret in "${declared[@]}"; do deployment+=(--secret "$secret=$dir/secrets/$secret"); done
  # The units come out as name and content, each ended by a NUL.
  in_image 'out=$(mktemp -d)
    /usr/local/share/denbox/render --format quadlet --output "$out" "$@"
    cd "$out"
    for unit in *; do printf "%s\0" "$unit"; cat -- "$unit"; printf "\0"; done' "${deployment[@]}" \
    > "$temporary/units"
  mkdir "$temporary/quadlet"
  while IFS= read -r -d '' unit && IFS= read -r -d '' content; do
    [[ $unit =~ ^denbox-[a-z0-9_-]+\.(container|volume)$ ]] || fail "deploy/render wrote an unexpected unit $unit"
    printf '%s' "$content" > "$temporary/quadlet/$unit"
  done < "$temporary/units"
fi

mv -f "$temporary/bootstrap.json" "$temporary/.env" "$temporary/accepted" "$dir/"
mv -f "$token" "$dir/git_token"
mkdir -p "$dir/secrets"
for secret in "${declared[@]}"; do mv -f "$temporary/secrets/$secret" "$dir/secrets/$secret"; done
if [[ $runtime == docker ]]; then
  mv -f "$temporary/compose.yaml" "$dir/compose.yaml"
  chmod 0644 "$dir/compose.yaml"
else
  rm -rf "$dir/quadlet"
  mv "$temporary/quadlet" "$dir/quadlet"
  chmod 0700 "$dir/quadlet"
fi

if [[ $runtime == docker ]]; then
  docker volume inspect "denbox-$name-home" > /dev/null 2>&1 || docker volume create "denbox-$name-home" > /dev/null
  # Compose reads only the rendered file, not this shell's settings.
  unset "${!DENBOX_@}" COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES
  docker compose --project-directory "$dir" -f "$dir/compose.yaml" up -d --force-recreate --pull never --remove-orphans
  cat <<EOF

The box denbox-$name is starting; its first build takes a while.
Installation: $dir (run install.sh again with --dir $dir to update)
Logs:  cd $dir && docker compose logs -f box
Shell: cd $dir && docker compose exec box denbox shell
EOF
else
  # Quadlet creates the volumes and the service from the units.
  units=${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd
  mkdir -p "$units"
  cp "$dir"/quadlet/* "$units/"
  systemctl --user daemon-reload
  systemctl --user restart "denbox-$name.service"
  cat <<EOF

The box denbox-$name is starting; its first build takes a while.
Installation: $dir (run install.sh again with --dir $dir to update)
Logs:  journalctl --user -u denbox-$name -f
Shell: podman exec -it denbox-$name denbox shell
EOF
fi
