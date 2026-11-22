# syntax=docker/dockerfile:1.7
# The box image: Debian, single-user Nix, git, tini and a seed copy of the
# runtime. Everything else a box runs comes from its environment.
#
#   docker build -f image/Dockerfile .
#
# The context is the repository root: the seed is built from this checkout.
ARG BASE_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
FROM ${BASE_IMAGE}
ARG TARGETARCH
ARG NIX_VERSION=2.34.1
# An unprivileged builder (rootless BuildKit) cannot load Nix's syscall filter.
ARG NIX_INSTALL_FILTER_SYSCALLS=true

# curl and xz-utils only fetch and unpack Nix; Nix has its own afterwards.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git tini xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p -m 0755 /etc/nix /nix /opt/nix \
    && printf '%s\n' 'experimental-features = nix-command flakes' 'sandbox = false' \
         'build-users-group =' > /etc/nix/nix.conf

# Single-user Nix owned by root: no daemon in the container, and the box runs
# as root. The installer warns about root and installs all the same.
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) system=x86_64-linux; checksum=92fc64a0740353215dec590508b9008cc8bd8e7c3d2b387a65da28146a78442f ;; \
      arm64) system=aarch64-linux; checksum=81aed0600605ee0494d2cd82c441b1ff6ecad7d3efcc6d4505a70aefc67b865c ;; \
      *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fSL "https://releases.nixos.org/nix/nix-${NIX_VERSION}/nix-${NIX_VERSION}-${system}.tar.xz" -o /tmp/nix.tar.xz; \
    echo "$checksum  /tmp/nix.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/nix.tar.xz -C /tmp; \
    NIX_CONFIG="filter-syscalls = $NIX_INSTALL_FILTER_SYSCALLS" HOME=/opt/nix USER=root \
      /tmp/nix-${NIX_VERSION}-${system}/install --no-daemon --no-channel-add --no-modify-profile; \
    rm -rf /tmp/nix.tar.xz /tmp/nix-${NIX_VERSION}-${system}; \
    ln -s "$(readlink -f /opt/nix/.nix-profile)" /nix/var/nix/gcroots/denbox-nix; \
    ln -s /nix/var/nix/gcroots/denbox-nix/bin/nix /usr/local/bin/nix; \
    usermod --shell /usr/local/libexec/denbox/login root

ENV HOME=/root \
    USER=root \
    NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PATH=/root/.nix-profile/bin:/nix/var/nix/gcroots/denbox-nix/bin:/usr/local/bin:/usr/bin:/bin \
    SHELL=/usr/local/libexec/denbox/login

# The seed: the runtime of this checkout, rooted so store maintenance keeps
# it. A box needs it only until its first activation installs its own.
COPY flake.nix flake.lock /tmp/denbox/
COPY kit /tmp/denbox/kit
RUN NIX_CONFIG="filter-syscalls = $NIX_INSTALL_FILTER_SYSCALLS" \
      nix build --out-link /nix/var/nix/gcroots/denbox-seed path:/tmp/denbox#runtime \
    && rm -rf /tmp/denbox \
    && nix store gc \
    && apt-get purge -y curl xz-utils

# denbox is the only command of the image on PATH. Root's login shell is kept
# off it: nothing in a box has a reason to call it by name.
COPY --chmod=0755 image/denbox /usr/local/bin/denbox
COPY --chmod=0755 image/login /usr/local/libexec/denbox/login
COPY --chmod=0644 image/profile.sh /etc/profile.d/denbox.sh
# The standard deployment and its Tailscale overlay, which install.sh reads
# out of the image.
COPY --chmod=0644 deploy/compose.yaml deploy/compose.tailscale.yaml /usr/local/share/denbox/

WORKDIR /root
# tini as PID 1 over the supervisor. The runtime clears what an earlier
# supervisor left in /run/denbox and refuses to start a second one.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/denbox", "supervise"]
