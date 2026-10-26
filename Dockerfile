# syntax=docker/dockerfile:1

# Source stages: pinned upstream images, multi-arch index digests.
# Keep each reference a plain image:tag@sha256:digest so Dependabot can update it.
FROM golang:1.27-trixie@sha256:fbb7ae40b62ff8afe31662df570d39b4f5052ac32b90dae8e60d7657a20a74f4 AS go
FROM node:26-trixie-slim@sha256:36793bcbb160a6a16cede1e62b93f84e26b78a972a8a4c0b879c1c12f22761ec AS node
FROM python:3.15-slim-trixie@sha256:533b0b2f9b5d46fd097091cf826f27902f1d6c3bca714b6dc74551356aa97a51 AS python
FROM ghcr.io/astral-sh/uv:0.13.5@sha256:32a7bb39b496babbd997b0a39a4d66c126bdaf5661b302bf6f06abda8deca6ff AS uv
FROM ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb AS oras
FROM hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d AS hadolint
FROM mvdan/shfmt:v3.14.1@sha256:8c06884a35683d8763fba6c0d9484d11a61a96da65f8d497d6f625825a6043f2 AS shfmt
FROM ghcr.io/jqlang/jq:1.8.2@sha256:b9c68867e5766576263a222e91db3de422d802069c7af70440e667a95344e486 AS jq
FROM mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e AS yq
FROM hairyhenderson/gomplate:v5.3.1@sha256:9c73c3cacc598cc9d926c67c5548901a4a4ee2223d29a2dacc910a68a5dfd684 AS gomplate
FROM golangci/golangci-lint:v2.15.0@sha256:fbfcfd12a6f8d7f1b97b3362ca80fc2a244d46863148c73cb88e7793af96c481 AS golangci-lint
FROM ghcr.io/pnpm/pnpm:12.15.0@sha256:d6148daf3ad2af8fa4ecd1aa06db73da32b2e37f63088987eea2fb375ee7f320 AS pnpm
FROM orhunp/git-cliff:2.14.2@sha256:1e696a381a1b0366bb6ccbb6bd4e50e73473fda88eab3a757b95e0d0d66c9531 AS git-cliff
FROM ghcr.io/betterleaks/betterleaks:v1.9.0@sha256:e3b95b0db6c2735db17165c009b0ad6d9cef34fb4578659232b98f69d7346cac AS betterleaks

# pnpm picks its command from argv[0] (pnpx/pnx run `pnpm dlx`), so the aliases must be
# hard links next to the binary; symlinks resolve to `pnpm`. COPY keeps the hard links.
FROM pnpm AS pnpm-dist
RUN for alias in pn pnpx pnx; do ln /opt/pnpm/pnpm "/opt/pnpm/$alias"; done

# GitHub CLI: no official image. Installs the latest release, verified against its
# published checksums; REFRESH makes scheduled builds pick up new releases.
FROM go AS gh
ARG TARGETARCH
ARG REFRESH
RUN --mount=type=bind,source=scripts/install-gh.sh,target=/tmp/install-gh.sh bash /tmp/install-gh.sh /opt/gh

# apt signing keys for the git-core PPA and Docker's repository, checked against
# their published fingerprints before the final stage trusts them.
FROM go AS apt-keys
RUN bash <<'EOF'
set -euxo pipefail
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
mkdir -p /keys
curl -fsSL --retry 3 -o /keys/git-core.asc \
  'https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0xF911AB184317630C59970973E363C90F8F1B6217'
curl -fsSL --retry 3 -o /keys/docker.asc https://download.docker.com/linux/ubuntu/gpg
check() {
  local fingerprints
  fingerprints=$(gpg --show-keys --with-colons "$1" | awk -F: '/^pub/{getline; print $10}')
  if [[ $fingerprints != "$2" ]]; then
    echo "unexpected key in $1: $fingerprints" >&2
    exit 1
  fi
}
check /keys/git-core.asc F911AB184317630C59970973E363C90F8F1B6217
check /keys/docker.asc 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
EOF

# jv, a JSON Schema validator: for the data files below, and shipped in the image. No upstream
# image publishes it, so it's built at a pinned version (bumped by hand); Go verifies the module
# against the checksum database. Static, with the LICENSE from the verified module.
FROM go AS jv
RUN bash <<'EOF'
set -euxo pipefail
module=github.com/santhosh-tekuri/jsonschema/cmd/jv@v0.7.0
CGO_ENABLED=0 GOBIN=/opt/jv go install "$module"
cp "$(go env GOMODCACHE)/$module/LICENSE" /opt/jv/LICENSE
EOF

# Task has no upstream image either. Build the pinned module with its verified license.
FROM go AS task
RUN bash <<'EOF'
set -euxo pipefail
module=github.com/go-task/task/v3
version=v3.54.0
CGO_ENABLED=0 GOBIN=/opt/task go install "$module/cmd/task@$version"
cp "$(go env GOMODCACHE)/$module@$version/LICENSE" /opt/task/LICENSE
EOF

# The scripts' data files (scripts/*.yaml): each validated against scripts/schemas/<name>.schema.json,
# checked for duplicate names, and converted to <name>.json. The scripts read only this output,
# never the YAML. `docker buildx bake config` runs it on its own and exports out/config/.
FROM go AS config-run
COPY --link --from=jv /opt/jv/jv /usr/local/bin/jv
COPY --link --from=yq /usr/bin/yq /usr/local/bin/yq
COPY --link --from=jq /jq /usr/local/bin/jq
RUN --mount=type=bind,source=scripts,target=/mnt/scripts bash <<'EOF'
set -euxo pipefail
mkdir /config
for schema in /mnt/scripts/schemas/*.schema.json; do
  name=$(basename "$schema" .schema.json)
  jv "$schema" "/mnt/scripts/$name.yaml"
  yq -o=json . "/mnt/scripts/$name.yaml" >"/config/$name.json"
  # Names identify entries across every list in a file; a schema can't express that.
  jq -e --arg file "scripts/$name.yaml" '[.[] | arrays | .[] | .name // .module] | group_by(.) | map(select(length > 1)[0]) |
    if length > 0 then error("\($file): duplicate names: \(join(", "))") else true end' "/config/$name.json"
done
EOF

FROM scratch AS config
COPY --from=config-run /config/ /

# Final image. Step order is chosen for cache reuse (docs/architecture.md#dockerfile-structure).
FROM ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944 AS image

# Selects the per-architecture apt lists cache: each architecture has its own lists.
ARG TARGETARCH

# Changes on scheduled builds, so every RUN below (apt and the agent installers) re-runs.
# COPY layers don't consume it and stay cached.
ARG REFRESH

# 1. Runtime packages, plus the shared libraries the copied Node and Python link against.
# sudo-rs depends on python3:any (for an apport hook), which would pull in Ubuntu's own
# Python. A local package declares that the copied Python provides python3. It owns only
# its copyright file, so a package that needs Ubuntu's real python3 can still install it.
# apt lists live in a cache mount shared by every apt step: never in a layer, and apt-get
# update only fetches what changed since the last build.
# The base image's Ubuntu sources use plain HTTP; every apt source is HTTPS instead. The base
# image has no CA certificates, so the first update and ca-certificates itself trust the go
# stage's bundle (a pinned image); everything after uses the installed store.
RUN --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,from=go,source=/etc/ssl/certs/ca-certificates.crt,target=/tmp/bootstrap-ca.crt bash <<'EOF'
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
sed -i 's|^URIs: http://|URIs: https://|' /etc/apt/sources.list.d/ubuntu.sources
if grep -hE '^[[:space:]]*(URIs:|deb)' /etc/apt/sources.list /etc/apt/sources.list.d/* | grep -q 'http://'; then
  echo "plain HTTP apt source left" >&2
  exit 1
fi
apt-get -o Acquire::https::CAInfo=/tmp/bootstrap-ca.crt update
apt-get -o Acquire::https::CAInfo=/tmp/bootstrap-ca.crt install -y --no-install-recommends ca-certificates
shim=$(mktemp -d)
mkdir "$shim/DEBIAN"
cat >"$shim/DEBIAN/control" <<CONTROL
Package: devcontainer-python3-shim
Version: 1.0
Architecture: $(dpkg --print-architecture)
Multi-Arch: allowed
Maintainer: devcontainer <noreply@localhost>
Provides: python3
Description: python3 is provided by the copied CPython in /usr/local
 Satisfies unversioned python3 dependencies with the image's copied interpreter
 instead of installing Ubuntu's python3.
CONTROL
mkdir -p "$shim/usr/share/doc/devcontainer-python3-shim"
cat >"$shim/usr/share/doc/devcontainer-python3-shim/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: devcontainer
Comment: Part of this project's image; see /legal/LICENSE.

Files: *
Copyright: none
License: CC0-1.0
 See /legal/LICENSE for the full text.
COPYRIGHT
dpkg-deb --build "$shim" /tmp/devcontainer-python3-shim.deb
dpkg -i /tmp/devcontainer-python3-shim.deb
rm -rf "$shim" /tmp/devcontainer-python3-shim.deb
apt-get upgrade -y
apt-get install -y --no-install-recommends \
  bash ca-certificates curl less locales openssh-client sudo-rs \
  media-types netbase tzdata \
  libatomic1 \
  libbz2-1.0 libdb5.3t64 libffi8 libgdbm6t64 liblzma5 libmpdec4 libncursesw6 \
  libreadline8t64 libsqlite3-0 libssl3t64 libtinfo6 libuuid1 libzstd1 zlib1g
EOF

# 2-3. git from the git-core PPA and Docker Engine from Docker's repository.
COPY --link --from=apt-keys /keys/ /etc/apt/keyrings/
RUN --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked bash <<'EOF'
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
cat >/etc/apt/sources.list.d/git-core.sources <<SOURCES
Types: deb
URIs: https://ppa.launchpadcontent.net/git-core/ppa/ubuntu
Suites: ${VERSION_CODENAME}
Components: main
Signed-By: /etc/apt/keyrings/git-core.asc
SOURCES
cat >/etc/apt/sources.list.d/docker.sources <<SOURCES
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
SOURCES
apt-get update
apt-get install -y --no-install-recommends git
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin containerd.io
# No apt installs follow, so record the exact .deb URL and checksum of every installed
# package (base image included) from the package lists.
mkdir -p /legal/provenance
# The python3 shim is this project's own package, not from a repository.
mapfile -t packages < <(dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package}=${Version}\n' | awk '$1 == "ii" && $2 !~ /^devcontainer-/ { print $2 }')
apt-get download --print-uris "${packages[@]}" >/legal/provenance/apt-uris.txt
[[ $(wc -l </legal/provenance/apt-uris.txt) -eq ${#packages[@]} ]]
EOF

# 4. Locale, with its ENV directly after so later steps run under it.
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANGUAGE=en_US:en

# 5. Toolchains and standalone tools. Independent --link layers stay cached when apt changes.
COPY --link --from=go /usr/local/go /usr/local/go
COPY --link --from=python /usr/local/ /usr/local/
COPY --link --from=node /usr/local/bin/node /usr/local/bin/node
COPY --link --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
COPY --link --chown=0:0 --from=pnpm-dist /opt/pnpm /opt/pnpm
COPY --link --chown=0:0 --chmod=0755 --from=uv /uv /uvx /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=oras /bin/oras /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=hadolint /bin/hadolint /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=shfmt /bin/shfmt /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=jq /jq /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=yq /usr/bin/yq /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=jv /opt/jv/jv /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=task /opt/task/task /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gomplate /gomplate /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=golangci-lint /usr/bin/golangci-lint /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=git-cliff /usr/local/bin/git-cliff /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=betterleaks /usr/bin/betterleaks /usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gh /opt/gh/gh /usr/local/bin/
RUN ldconfig

# 6. Image files (BASH_ENV script, start-dockerd).
COPY rootfs/ /

# 7. Every primary command resolves from /usr/local/bin (see "Default PATH").
RUN bash <<'EOF'
set -euxo pipefail
ln -sf /usr/local/go/bin/* /usr/local/bin/
ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm
ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
for bin in pnpm pn pnpx pnx; do
  ln -s "/opt/pnpm/$bin" "/usr/local/bin/$bin"
done
EOF

ENV GOPATH=/go \
    GOTOOLCHAIN=local \
    BASH_ENV=/etc/devcontainer/env.sh \
    PNPM_HOME=/usr/local/share/pnpm \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/go/bin

# 8. Shared GOPATH: root:staff, group-writable, setgid.
RUN bash <<'EOF'
set -euxo pipefail
mkdir -p /go/src /go/bin
chown -R root:staff /go
chmod -R 775 /go
chmod 2775 /go /go/src /go/bin
go version
EOF

# 9. Rename the stock ubuntu user to agent; passwordless sudo that keeps PATH.
RUN bash <<'EOF'
set -euxo pipefail
usermod --login agent --home /home/agent --move-home ubuntu
groupmod --new-name agent ubuntu
# Only docker and staff: drop the stock ubuntu user's adm, sudo, cdrom, ... groups.
usermod --groups docker,staff agent
sed -i '/^Defaults[[:space:]]\+secure_path/d' /etc/sudoers
if grep -q secure_path /etc/sudoers; then
  echo "secure_path still set in /etc/sudoers" >&2
  exit 1
fi
cat >/etc/sudoers.d/agent <<'SUDOERS'
Defaults env_keep += "PATH HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY http_proxy https_proxy ftp_proxy no_proxy"
agent ALL=(ALL) NOPASSWD:ALL
SUDOERS
chmod 0440 /etc/sudoers /etc/sudoers.d/agent
visudo -c
install -d -o agent -g agent /home/agent/workspace
EOF

# 10. Shared /usr/local/bin: the directory only, never recursively.
RUN chown root:staff /usr/local/bin && chmod 2775 /usr/local/bin

# 11. pnpm configuration for every user and HOME (see "pnpm configuration").
ENV pnpm_config_global_bin_dir=/usr/local/bin \
    pnpm_config_global_dir=/usr/local/share/pnpm/global \
    pnpm_config_store_dir=/usr/local/share/pnpm/store \
    pnpm_config_fetch_retries=6 \
    pnpm_config_fetch_retry_factor=2 \
    pnpm_config_fetch_retry_mintimeout=3750 \
    pnpm_config_fetch_retry_maxtimeout=120000 \
    pnpm_config_strict_ssl=true \
    pnpm_config_prefer_offline=true \
    pnpm_config_prefer_frozen_lockfile=true \
    pnpm_config_verify_store_integrity=true \
    pnpm_config_update_notifier=false
RUN bash <<'EOF'
set -euxo pipefail
mkdir -p "$PNPM_HOME/global" "$PNPM_HOME/store"
chown -R root:staff "$PNPM_HOME"
find "$PNPM_HOME" -type d -exec chmod 2775 {} +
find "$PNPM_HOME" -type f -exec chmod g+w {} +
EOF

# 12. Agent CLIs, installed as agent so they can self-update.
USER agent
RUN bash <<'EOF'
set -euxo pipefail
curl -fsSL https://claude.ai/install.sh | bash
curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
# The installer runs codex once, leaving arg0 temp dirs. In a lower image layer they
# can't be renamed away (overlayfs EXDEV), so codex warns on every start.
rm -rf "$HOME/.codex/tmp"
# Runtime leftovers: Claude Code's socket directory and Node's compile cache.
rm -rf /tmp/cc-socks /tmp/node-compile-cache
EOF

# 13. Chained links, so the agents resolve for root too and survive self-updates.
USER root
RUN ln -s /home/agent/.local/bin/claude /home/agent/.local/bin/codex /usr/local/bin/

# 14. /legal: project license, vendored and image-sourced notices, then the generated
# manifest.tsv (see docs/legal.md).
COPY LICENSE /legal/LICENSE
COPY legal/README.md legal/SOURCE.md /legal/
COPY --from=go /usr/local/go/LICENSE /usr/local/go/PATENTS /legal/attribution/go/
COPY --from=python /usr/local/lib/python3.15/LICENSE.txt /legal/attribution/python/
COPY --from=jq /COPYING /legal/attribution/jq/
COPY --from=jv /opt/jv/LICENSE /legal/attribution/jv/
COPY --from=task /opt/task/LICENSE /legal/attribution/task/
ARG REVISION
RUN --mount=type=bind,target=/mnt/legal-src --mount=type=bind,from=gh,source=/opt/gh,target=/mnt/gh-legal \
    --mount=type=bind,from=config,target=/mnt/config \
    --mount=type=cache,id=legal-go-mod,target=/var/cache/legal-go-mod,sharing=locked bash <<'EOF'
set -euxo pipefail
bash /mnt/legal-src/scripts/collect-legal.sh /mnt/legal-src/Dockerfile /mnt/config /mnt/gh-legal
# The version checks run node as root, which leaves a compile cache behind.
rm -rf /tmp/node-compile-cache
EOF

# 15. Defaults for every context.
LABEL org.opencontainers.image.title="devcontainer" \
      org.opencontainers.image.description="Ubuntu 26.04 LTS image with one pinned toolset for devcontainers, GitHub Actions CI, and agent sandboxes. Copyleft source is attached as OCI referrers; see /legal/SOURCE.md." \
      org.opencontainers.image.licenses="CC0-1.0" \
      org.opencontainers.image.vendor="frithuz" \
      devcontainer.metadata='[{"remoteUser":"agent"}]'
USER agent
WORKDIR /home/agent/workspace
CMD ["/bin/bash"]

# Preflight: smoke tests run here (Phase 5); never published. Also exports the image's
# manifest.tsv, from which scripts/plan-sources.sh derives the source images.
FROM image AS preflight-run
RUN bash <<'EOF'
set -euxo pipefail
mkdir -p /tmp/out
echo "preflight placeholder" >/tmp/out/report.txt
task --version >>/tmp/out/report.txt
cp /legal/manifest.tsv /tmp/out/manifest.tsv
EOF

FROM scratch AS preflight
COPY --from=preflight-run /tmp/out/ /

# Default target for a plain `docker build`: the image, not the preflight report.
FROM image AS default
