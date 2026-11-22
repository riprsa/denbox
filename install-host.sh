#!/usr/bin/env bash
# Installs a box on a Debian or Ubuntu machine with systemd, without a
# container, or updates one installed before. Run it as root.
#
#   bash install-host.sh [--repository URL] [--ref REF] [--box BOX] [--name NAME]
#                        [--token-file FILE] [--seed FLAKEREF]
#
# Each option is also read from a variable: DENBOX_REPOSITORY, DENBOX_REF,
# DENBOX_BOX, DENBOX_NAME, DENBOX_GIT_TOKEN_FILE, DENBOX_SEED, and
# DENBOX_GIT_TOKEN for the token itself. What is missing is asked on the
# terminal; the token only when the repository is not readable without one.
# DENBOX_SYNC_INTERVAL goes into the bootstrap. NAME (default BOX) names the
# unit denbox-NAME.service. SEED is the flake the first runtime is built
# from, this repository's default branch unless given (a revision to pin
# it, or a local checkout as path:DIR).
#
# The box names its user: the installer reads home.username and
# home.homeDirectory of the box, creates that user when it is missing, and
# runs the box as that user. Run again with the same name, it updates the
# unit and the seed with the settings it saved and restarts the box. It never
# deletes or rewrites a home.
set -euo pipefail
umask 077

# Every path the installer writes is under this directory; tests point it at
# a temporary one. The files it writes name the paths without it.
root=${DENBOX_HOST_ROOT:-}
nix_version=2.34.1
# The seed runs only until the box's first activation installs the runtime
# that the box's own lock names, so the latest one is good enough to start.
seed_default=github:riprsa/denbox
nix=/nix/var/nix/profiles/default/bin/nix
nix_conf=/etc/nix/nix.conf
seed_link=/nix/var/nix/gcroots/denbox-seed

fail() { printf 'denbox install-host: %s\n' "$*" >&2; exit 1; }
# usage: the comment at the top of this file.
usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0" >&2; exit 64; }

repository=${DENBOX_REPOSITORY:-} ref=${DENBOX_REF:-} box=${DENBOX_BOX:-} name=${DENBOX_NAME:-}
token_file=${DENBOX_GIT_TOKEN_FILE:-} seed=${DENBOX_SEED:-} interval=${DENBOX_SYNC_INTERVAL:-}
while (($#)); do
  [[ $# -ge 2 ]] || usage
  case $1 in
    --repository) repository=$2 ;;
    --ref) ref=$2 ;;
    --box) box=$2 ;;
    --name) name=$2 ;;
    --token-file) token_file=$2 ;;
    --seed) seed=$2 ;;
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

# The token goes into a file at once and out of the environment.
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
[[ $(id -u) == 0 ]] || fail 'Run this as root'

# terminal: whether there is a terminal to ask on.
terminal() { { : < /dev/tty; } 2> /dev/null; }

# ask VARIABLE PROMPT [DEFAULT]: reads a value from the terminal when the
# variable is empty; without a terminal the default holds.
ask() {
  local answer
  [[ -z ${!1} ]] || return 0
  if [[ -n ${3:-} ]] && ! terminal; then printf -v "$1" '%s' "$3"; return 0; fi
  terminal || fail "No terminal to ask on; give $2 up front (see the top of install-host.sh)"
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

# load_saved FILE: the settings an earlier run saved, for what neither an
# option nor a variable gives.
load_saved() {
  local key value
  while IFS='=' read -r key value; do
    case $key in
      DENBOX_REPOSITORY) repository=${repository:-$value} ;;
      DENBOX_REF) ref=${ref:-$value} ;;
      DENBOX_BOX) box=${box:-$value} ;;
      DENBOX_SEED) seed=${seed:-$value} ;;
      DENBOX_SYNC_INTERVAL) interval=${interval:-$value} ;;
    esac
  done < "$1"
}

name=${name:-$box}
[[ -z $name || ! -f $root/etc/denbox/$name/settings ]] || load_saved "$root/etc/denbox/$name/settings"
ask repository 'Environment repository URL'
ask ref 'Branch' main
ask box 'Box name'
name=${name:-$box}
seed=${seed:-$seed_default}
etc=/etc/denbox/$name
unit=denbox-$name.service

[[ $repository =~ ^[A-Za-z0-9+.:/@_~%-]+$ ]] || fail "Not a repository URL: $repository"
# The URL is on command lines and in the bootstrap; a token goes in the token file.
[[ ! $repository =~ ://[^/@]*:[^/@]*@ ]] || fail 'Give the token as the token, not in the repository URL'
[[ $ref =~ ^[A-Za-z0-9._/-]+$ && $ref != -* ]] || fail "Not a branch name: $ref"
[[ $box =~ ^[A-Za-z0-9_-]+$ ]] || fail "Not a box name: $box"
[[ $name =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "Not a name for a unit (lowercase letters, digits, _ and -): $name; give --name"
flakeref='^[A-Za-z0-9+.:/@_~%?=&-]+$'
[[ $seed =~ $flakeref ]] || fail "Not a flake reference: $seed"
[[ -z $interval || ($interval =~ ^[1-9][0-9]*$ && $interval -ge 30 && $interval -le 86400) ]] ||
  fail "Not a sync interval from 30 to 86400 seconds: $interval"
[[ -d $root/run/systemd/system ]] || fail 'systemd is not running on this machine'

# Fetching Nix and the environment needs curl, xz and git; a stock Debian
# or Ubuntu may lack some of them.
missing=()
for package in curl:curl xz:xz-utils git:git; do
  command -v "${package%%:*}" > /dev/null || missing+=("${package#*:}")
done
if ((${#missing[@]})); then
  command -v apt-get > /dev/null || fail "Install ${missing[*]} first; this installer knows only apt"
  echo "Installing ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends ca-certificates "${missing[@]}"
fi

# install_nix: multi-user Nix with its daemon, the pinned release. The daemon
# builds as its own users in a sandbox, so a box that does not run as root
# builds, roots and collects the store through it, with nothing the container
# needs (no sandbox = false, no single owner of /nix).
install_nix() {
  local system checksum
  case $(uname -m) in
    x86_64) system=x86_64-linux; checksum=92fc64a0740353215dec590508b9008cc8bd8e7c3d2b387a65da28146a78442f ;;
    aarch64) system=aarch64-linux; checksum=81aed0600605ee0494d2cd82c441b1ff6ecad7d3efcc6d4505a70aefc67b865c ;;
    *) fail "Unsupported architecture: $(uname -m)" ;;
  esac
  echo "Installing Nix $nix_version with its daemon"
  curl -fsSL "https://releases.nixos.org/nix/nix-$nix_version/nix-$nix_version-$system.tar.xz" -o "$temporary/nix.tar.xz"
  echo "$checksum  $temporary/nix.tar.xz" | sha256sum -c --quiet - || fail 'The Nix release does not match its checksum'
  tar -xJf "$temporary/nix.tar.xz" -C "$temporary"
  printf '%s\n' 'experimental-features = nix-command flakes' > "$temporary/nix.conf"
  # Nix's files are for every user, not under this script's umask.
  (umask 022 && "$temporary/nix-$nix_version-$system/install" --daemon --yes --no-channel-add \
    --nix-extra-conf-file "$temporary/nix.conf" < /dev/null)
}
if [[ ! -x $root$nix ]]; then
  install_nix
else
  # The box's user builds through the daemon; a single-user Nix has none.
  systemctl is-active --quiet nix-daemon.socket nix-daemon.service ||
    fail 'Nix is installed without its daemon; this installer needs multi-user Nix'
fi
# The runtime asks Nix for the kit's binary cache. Through the daemon Nix
# takes a substituter and its key from a user only when the daemon trusts
# them; these lines trust that one cache without turning it on for every
# user of the machine.
trust=(
  'extra-trusted-substituters = https://denbox.cachix.org'
  'extra-trusted-public-keys = denbox.cachix.org-1:0wTpaHGYAg3yirdzhxYjNPnzPjVjBiNoMHaK4Hptx9I='
)
trusted=true
for line in "${trust[@]}"; do
  grep -qxF "$line" "$root$nix_conf" 2> /dev/null || trusted=false
done
if [[ $trusted == false ]]; then
  echo "Trusting the denbox binary cache in $nix_conf"
  install -d -m 0755 "$root${nix_conf%/*}"
  [[ -f $root$nix_conf ]] || install -m 0644 /dev/null "$root$nix_conf"
  [[ -z $(tail -c 1 "$root$nix_conf") ]] || echo >> "$root$nix_conf"
  for line in "${trust[@]}"; do
    grep -qxF "$line" "$root$nix_conf" || printf '%s\n' "$line" >> "$root$nix_conf"
  done
  systemctl restart nix-daemon.service
fi

# Flakes for the installer's own calls, whatever nix.conf says.
export NIX_CONFIG='extra-experimental-features = nix-command flakes'

# The seed: the first runtime the box runs, rooted so store maintenance keeps
# it. The box's own runtime takes over after its first activation.
echo "Building the runtime from $seed"
"$root$nix" build --out-link "$root$seed_link" "$seed#runtime"
askpass=$root$seed_link/libexec/denbox/askpass

# remote GIT-ARGS: Git without the user's or the system's configuration,
# with the token in $token through the seed's askpass.
remote() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=$askpass DENBOX_GIT_TOKEN=$token \
    git -c credential.helper= -c http.followRedirects=false "$@"
}
# readable: 0 when Git reads the branch with the token in $token (none when
# the file is empty), 2 when the branch is missing, other codes otherwise.
readable() { remote ls-remote --exit-code "$repository" "refs/heads/$ref" > /dev/null; }
if [[ $token_given == false ]]; then
  if [[ -f $root$etc/git_token ]]; then cp "$root$etc/git_token" "$token"; else : > "$token"; fi
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

# The box says who it runs as: its home.username and home.homeDirectory.
echo "Reading boxes.$box of $repository at $ref"
git init -q --bare "$temporary/source.git"
remote --git-dir="$temporary/source.git" fetch -q --depth=1 "$repository" "refs/heads/$ref"
mkdir "$temporary/snapshot"
git --git-dir="$temporary/source.git" archive FETCH_HEAD | tar -x -C "$temporary/snapshot"
# shellcheck disable=SC2016 # a Nix expression, not a shell one
home_config=$("$root$nix" eval --raw --no-write-lock-file "path:$temporary/snapshot#boxes.$box.config.home" \
  --apply 'home: "${home.username} ${home.homeDirectory}"')
read -r user home <<<"$home_config"
[[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "boxes.$box sets home.username to $user, not a user name"
[[ $home =~ ^/[A-Za-z0-9._/-]*$ ]] || fail "boxes.$box sets home.homeDirectory to $home, not a path"

# One box per user: two would share one home and its state.
for other in "$root"/etc/systemd/system/denbox-*.service; do
  [[ -f $other && ${other##*/} != "$unit" ]] || continue
  ! grep -qx "User=$user" "$other" || fail "The user $user runs the box of ${other##*/} already"
done

if ! getent passwd "$user" > /dev/null; then
  [[ $user != root ]] || fail 'This machine has no root user'
  echo "Creating the user $user with the home $home"
  useradd --create-home --home-dir "$home" --user-group --shell /bin/bash "$user"
fi
IFS=: read -r _ _ _ gid _ passwd_home _ <<<"$(getent passwd "$user")"
[[ $passwd_home == "$home" ]] ||
  fail "The home of $user is $passwd_home; boxes.$box says $home. Set home.homeDirectory to it"
group=$(getent group "$gid" | cut -d: -f1)
# The bootstrap and the token are readable by the user's primary group, so
# that group must be the user's alone.
if [[ $user != root ]]; then
  IFS=: read -r _ _ _ members <<<"$(getent group "$gid")"
  [[ -z $members && $(getent passwd | awk -F: -v gid="$gid" '$4 == gid' | wc -l) == 1 ]] ||
    fail "The primary group $group of $user is shared; give $user a group of its own"
fi
if [[ ! -d $root$home ]]; then
  (umask 022 && mkdir -p "$root$home")
  chown "$user:$group" "$root$home"
  chmod 0700 "$root$home"
fi

# The bootstrap and the token: root writes them, the box's user reads them.
# /etc/denbox lets every box's user through to its own directory.
install -d -m 0755 "$root/etc/denbox"
install -d "$root$etc"
printf '{"version": 2, "repository": "%s", "ref": "%s", "box": "%s"%s}\n' "$repository" "$ref" "$box" \
  "${interval:+, \"sync_interval\": $interval}" > "$temporary/bootstrap.json"
printf '%s=%s\n' DENBOX_REPOSITORY "$repository" DENBOX_REF "$ref" DENBOX_BOX "$box" DENBOX_SEED "$seed" \
  > "$temporary/settings"
[[ -z $interval ]] || printf 'DENBOX_SYNC_INTERVAL=%s\n' "$interval" >> "$temporary/settings"
mv -f "$temporary/bootstrap.json" "$temporary/settings" "$root$etc/"
mv -f "$token" "$root$etc/git_token"
chown "root:$group" "$root$etc" "$root$etc/bootstrap.json" "$root$etc/git_token"
chmod 0750 "$root$etc"
chmod 0640 "$root$etc/bootstrap.json" "$root$etc/git_token"
chmod 0600 "$root$etc/settings"

# denbox on PATH, as in the image: the box's own runtime once its activation
# installed it, the seed before.
install -d -m 0755 "$root/usr/local/bin"
cat > "$temporary/denbox" <<EOF
#!/bin/sh
# denbox on PATH: the box's own runtime once its activation installed it,
# the seed before. Written by install-host.sh.
profile=\${HOME:-/root}/.nix-profile/bin/denbox
if [ -x "\$profile" ]; then exec "\$profile" "\$@"; fi
exec $seed_link/bin/denbox "\$@"
EOF
chmod 0755 "$temporary/denbox"
mv -f "$temporary/denbox" "$root/usr/local/bin/denbox"

# The unit. systemd makes the runtime's directory, empty at every start.
# The runtime finds the same directory by its user when no variable says so.
if [[ $user == root ]]; then run=denbox; else run=denbox-$user; fi
cat > "$temporary/unit" <<EOF
# The denbox box $name, written by install-host.sh; run it again to update.
[Unit]
Description=denbox box $name
Wants=network-online.target nix-daemon.socket
After=network-online.target nix-daemon.socket nix-daemon.service

[Service]
User=$user
Group=$group
WorkingDirectory=~
RuntimeDirectory=$run
RuntimeDirectoryMode=0700
Environment=PATH=$home/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin
Environment="NIX_CONFIG=extra-experimental-features = nix-command flakes"
Environment=DENBOX_RUN=/run/$run
Environment=DENBOX_BOOTSTRAP=$etc/bootstrap.json
Environment=DENBOX_GIT_TOKEN=$etc/git_token
ExecStart=/usr/local/bin/denbox supervise
# s6-svscan stops the services on TERM; each has 30 seconds.
KillMode=mixed
TimeoutStopSec=90
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
install -d -m 0755 "$root/etc/systemd/system"
chmod 0644 "$temporary/unit"
mv -f "$temporary/unit" "$root/etc/systemd/system/$unit"

systemctl daemon-reload
systemctl enable --quiet "$unit"
systemctl restart "$unit"

cat <<EOF

The box $name is starting as $user; its first build takes a while.
Settings: $etc (run install-host.sh --name $name again to update)
Logs:  journalctl -u $unit -f
Shell: su - $user -c 'denbox shell'
EOF
