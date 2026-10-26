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
FROM ghcr.io/nushell/nushell:0.116.1-bookworm@sha256:3de167aad209014bffbc3ed90fc433199b1a835c88a91befe8aa9d9b7db2d428 AS nushell

# Builder stages run their scripts in nu (AGENTS.md), so they start from go with nu added.
FROM go AS builder
COPY --link --from=nushell /usr/bin/nu /usr/local/bin/nu

# GitHub CLI: no official image. Installs the latest release, verified against its
# published checksums; REFRESH makes scheduled builds pick up new releases.
FROM go AS gh
ARG TARGETARCH
ARG REFRESH
RUN --mount=type=bind,source=scripts/install-gh.sh,target=/tmp/install-gh.sh bash /tmp/install-gh.sh /opt/gh

# apt signing keys for the git-core PPA and Docker's repository, checked against
# their published fingerprints before the final stage trusts them.
FROM builder AS apt-keys
RUN nu /dev/stdin <<'EOF'
$env.GNUPGHOME = (mktemp -d)
mkdir /keys
http get 'https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0xF911AB184317630C59970973E363C90F8F1B6217'
  | save /keys/git-core.asc
http get https://download.docker.com/linux/ubuntu/gpg | save /keys/docker.asc
# The fingerprint is field 10 of the fpr line after each pub line.
def check [file: string, expected: string] {
  let rows = gpg --show-keys --with-colons $file | lines
  let fingerprints = $rows | enumerate | where {|row| $row.item starts-with 'pub:' }
    | each {|row| $rows | get ($row.index + 1) | split row ':' | get 9 }
    | str join "\n"
  if $fingerprints != $expected {
    error make {msg: $"unexpected key in ($file): ($fingerprints)"}
  }
}
check /keys/git-core.asc F911AB184317630C59970973E363C90F8F1B6217
check /keys/docker.asc 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
EOF

# jv, a JSON Schema validator: for the data files below, and shipped in the image. No upstream
# image publishes it, so it's built at a pinned version (bumped by hand); Go verifies the module
# against the checksum database. Static, with the LICENSE from the verified module.
FROM builder AS jv
RUN nu /dev/stdin <<'EOF'
let module = 'github.com/santhosh-tekuri/jsonschema/cmd/jv@v0.7.0'
CGO_ENABLED=0 GOBIN=/opt/jv go install $module
cp $"(go env GOMODCACHE | str trim)/($module)/LICENSE" /opt/jv/LICENSE
EOF

# Task has no upstream image either. Build the pinned module with its verified license.
FROM builder AS task
RUN nu /dev/stdin <<'EOF'
let module = 'github.com/go-task/task/v3@v3.54.0'
let path = $module | split row '@' | first
let version = $module | split row '@' | last
CGO_ENABLED=0 GOBIN=/opt/task go install $"($path)/cmd/task@($version)"
cp $"(go env GOMODCACHE | str trim)/($module)/LICENSE" /opt/task/LICENSE
EOF

# The scripts' data files (scripts/*.yaml): each validated against scripts/schemas/<name>.schema.json,
# checked for duplicate names, and converted to <name>.json. The scripts read only this output,
# never the YAML. `docker buildx bake config` runs it on its own and exports out/config/.
FROM builder AS config-run
COPY --link --from=jv /opt/jv/jv /usr/local/bin/jv
RUN --mount=type=bind,source=scripts,target=/mnt/scripts nu /dev/stdin <<'EOF'
mkdir /config
for schema in (glob /mnt/scripts/schemas/*.schema.json | sort) {
  let name = $schema | path basename | str replace --regex '\.schema\.json$' ''
  let yaml = $"/mnt/scripts/($name).yaml"
  print $"validating scripts/($name).yaml"
  jv $schema $yaml
  let data = open $yaml
  $data | to json | save $"/config/($name).json"
  # Names identify entries across every list in a file; a schema can't express that.
  let duplicates = $data | values | where ($it | describe) =~ '^(list|table)'
    | each {|list| $list | each {|entry| $entry.name? | default $entry.module? } }
    | flatten | uniq --repeated
  if ($duplicates | is-not-empty) {
    error make {msg: $"scripts/($name).yaml: duplicate names: ($duplicates | str join ', ')"}
  }
}
EOF

FROM scratch AS config
COPY --from=config-run /config/ /

# Every file the image copies in, laid out under /out as it lands in the image: toolchains and
# standalone tools, the apt signing keys, image files (rootfs/: the BASH_ENV script and
# start-dockerd), and the notices /legal starts from. The image takes it as its first layer.
FROM builder AS files
COPY --link --from=go /usr/local/go /out/usr/local/go
COPY --link --from=python /usr/local/ /out/usr/local/
COPY --link --from=node /usr/local/bin/node /out/usr/local/bin/node
COPY --link --from=node /usr/local/lib/node_modules/npm /out/usr/local/lib/node_modules/npm
COPY --link --chown=0:0 --from=pnpm /opt/pnpm /out/opt/pnpm
COPY --link --chown=0:0 --chmod=0755 --from=uv /uv /uvx /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=oras /bin/oras /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=hadolint /bin/hadolint /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=shfmt /bin/shfmt /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=jq /jq /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=yq /usr/bin/yq /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=jv /opt/jv/jv /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=task /opt/task/task /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gomplate /gomplate /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=golangci-lint /usr/bin/golangci-lint /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=git-cliff /usr/local/bin/git-cliff /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=betterleaks /usr/bin/betterleaks /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=nushell /usr/bin/nu /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gh /opt/gh/gh /out/usr/local/bin/
COPY --link --from=apt-keys /keys/ /out/etc/apt/keyrings/
COPY --link rootfs/ /out/
COPY --link LICENSE /out/legal/LICENSE
COPY --link legal/README.md legal/SOURCE.md /out/legal/
COPY --link --from=go /usr/local/go/LICENSE /usr/local/go/PATENTS /out/legal/attribution/go/
COPY --link --from=python /usr/local/lib/python3.15/LICENSE.txt /out/legal/attribution/python/
COPY --link --from=jq /COPYING /out/legal/attribution/jq/
COPY --link --from=jv /opt/jv/LICENSE /out/legal/attribution/jv/
COPY --link --from=task /opt/task/LICENSE /out/legal/attribution/task/
COPY --link --from=nushell /usr/bin/LICENSE /out/legal/attribution/nushell/
RUN nu /dev/stdin <<'EOF'
# pnpm picks its command from argv[0] (pnpx/pnx run `pnpm dlx`), so the aliases must be hard
# links next to the binary; symlinks resolve to `pnpm`. The image's single COPY keeps them.
for alias in [pn pnpx pnx] {
  ^ln /out/opt/pnpm/pnpm $"/out/opt/pnpm/($alias)"
}
# Every primary command resolves from /usr/local/bin (see "Default PATH").
cd /out/usr/local/bin
for bin in (ls /out/usr/local/go/bin | get name | path basename) {
  ^ln -s $"/usr/local/go/bin/($bin)" $bin
}
^ln -s ../lib/node_modules/npm/bin/npm-cli.js npm
^ln -s ../lib/node_modules/npm/bin/npx-cli.js npx
for bin in [pnpm pn pnpx pnx] {
  ^ln -s $"/opt/pnpm/($bin)" $bin
}
EOF

# Final image: three layers, every copied file, then the system and agents, then /legal
# (docs/architecture.md#dockerfile-structure).
FROM ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944 AS image

# Selects the per-architecture apt lists cache: each architecture has its own lists.
ARG TARGETARCH

# Changes on scheduled builds, so every RUN below (apt and the agent installers) re-runs.
# The COPY doesn't consume it and stays cached.
ARG REFRESH

# 1. Every copied file, first, so the setup below can use the toolchains and nu.
COPY --link --from=files /out/ /

# 2. The system and the agents, in one step.
# Runtime packages, plus the shared libraries the copied Node and Python link against.
# sudo-rs depends on python3:any (for an apport hook), which would pull in Ubuntu's own
# Python. A local package declares that the copied Python provides python3. It owns only
# its copyright file, so a package that needs Ubuntu's real python3 can still install it.
# apt lists live in a cache mount: never in a layer, and apt-get update only fetches what
# changed since the last build.
# The base image's Ubuntu sources use plain HTTP; every apt source is HTTPS instead. The base
# image has no CA certificates, so the first update and ca-certificates itself trust the go
# stage's bundle (a pinned image); everything after uses the installed store.
RUN --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,from=go,source=/etc/ssl/certs/ca-certificates.crt,target=/tmp/bootstrap-ca.crt nu /dev/stdin <<'EOF'
$env.DEBIAN_FRONTEND = 'noninteractive'
let arch = dpkg --print-architecture | str trim

# Read each file fully before saving over it: save truncates it while a pipeline still reads.
let ubuntu_sources = '/etc/apt/sources.list.d/ubuntu.sources'
let https_sources = open --raw $ubuntu_sources
  | str replace --all --regex '(?m)^URIs: http://' 'URIs: https://'
$https_sources | save --force $ubuntu_sources
let plain = glob /etc/apt/{sources.list,sources.list.d/*}
  | each {|file| open --raw $file | lines } | flatten
  | where $it =~ '^\s*(URIs:|deb)' and $it =~ 'http://'
if ($plain | is-not-empty) {
  error make {msg: $"plain HTTP apt source left: ($plain | str join ', ')"}
}
let bootstrap = [-o Acquire::https::CAInfo=/tmp/bootstrap-ca.crt]
apt-get ...$bootstrap update
apt-get ...$bootstrap install -y --no-install-recommends ca-certificates

let shim = mktemp -d
mkdir $"($shim)/DEBIAN" $"($shim)/usr/share/doc/devcontainer-python3-shim"
$"Package: devcontainer-python3-shim
Version: 1.0
Architecture: ($arch)
Multi-Arch: allowed
Maintainer: devcontainer <noreply@localhost>
Provides: python3
Description: python3 is provided by the copied CPython in /usr/local
 Satisfies unversioned python3 dependencies with the image's copied interpreter
 instead of installing Ubuntu's python3.
" | save $"($shim)/DEBIAN/control"
r#'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: devcontainer
Comment: Part of this project's image; see /legal/LICENSE.

Files: *
Copyright: none
License: CC0-1.0
 See /legal/LICENSE for the full text.
'# | save $"($shim)/usr/share/doc/devcontainer-python3-shim/copyright"
dpkg-deb --build $shim /tmp/devcontainer-python3-shim.deb
dpkg -i /tmp/devcontainer-python3-shim.deb
rm -rf $shim /tmp/devcontainer-python3-shim.deb
apt-get upgrade -y
let packages = [
  bash ca-certificates curl less locales openssh-client sudo-rs
  media-types netbase tzdata
  libatomic1
  libbz2-1.0 libdb5.3t64 libffi8 libgdbm6t64 liblzma5 libmpdec4 libncursesw6
  libreadline8t64 libsqlite3-0 libssl3t64 libtinfo6 libuuid1 libzstd1 zlib1g
]
apt-get install -y --no-install-recommends ...$packages

# git from the git-core PPA and Docker Engine from Docker's repository.
let codename = open --raw /etc/os-release | lines
  | where $it starts-with 'VERSION_CODENAME=' | first
  | str replace 'VERSION_CODENAME=' '' | str trim --char '"'
$"Types: deb
URIs: https://ppa.launchpadcontent.net/git-core/ppa/ubuntu
Suites: ($codename)
Components: main
Signed-By: /etc/apt/keyrings/git-core.asc
" | save /etc/apt/sources.list.d/git-core.sources
$"Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ($codename)
Components: stable
Architectures: ($arch)
Signed-By: /etc/apt/keyrings/docker.asc
" | save /etc/apt/sources.list.d/docker.sources
apt-get update
apt-get install -y --no-install-recommends git
(apt-get install -y --no-install-recommends
  docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin containerd.io)

# No apt installs follow, so record the exact .deb URL and checksum of every installed
# package (base image included) from the package lists.
mkdir /legal/provenance
# The python3 shim is this project's own package, not from a repository.
let installed = dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package}=${Version}\n' | lines
  | each {|line| $line | split row --regex '\s+' }
  | where {|fields| $fields.0 == 'ii' and not ($fields.1 starts-with 'devcontainer-') }
  | each {|fields| $fields.1 }
apt-get download --print-uris ...$installed | save /legal/provenance/apt-uris.txt
let recorded = open --raw /legal/provenance/apt-uris.txt | lines | length
if $recorded != ($installed | length) {
  error make {msg: $"apt-uris.txt has ($recorded) entries for ($installed | length) packages"}
}

# The locale the ENV below selects, and the copied shared libraries.
locale-gen en_US.UTF-8
ldconfig

# Shared GOPATH: root:staff, group-writable, setgid.
mkdir /go/src /go/bin
chown -R root:staff /go
chmod -R 775 /go
chmod 2775 /go /go/src /go/bin
go version

# Rename the stock ubuntu user to agent, with nu as its login shell; passwordless sudo that
# keeps PATH.
usermod --login agent --home /home/agent --move-home ubuntu
groupmod --new-name agent ubuntu
# Only docker and staff: drop the stock ubuntu user's adm, sudo, cdrom, ... groups.
usermod --groups docker,staff agent
"/usr/local/bin/nu\n" | save --append /etc/shells
usermod --shell /usr/local/bin/nu agent
let sudoers = open --raw /etc/sudoers | lines | where $it !~ '^Defaults\s+secure_path' | append ''
  | str join "\n"
$sudoers | save --force /etc/sudoers
if (open --raw /etc/sudoers | str contains secure_path) {
  error make {msg: 'secure_path still set in /etc/sudoers'}
}
# visudo -c accepts an empty file, so check that the drop-in below is still included.
if not (open --raw /etc/sudoers | lines | any {|line| $line == '@includedir /etc/sudoers.d' }) {
  error make {msg: '/etc/sudoers no longer includes /etc/sudoers.d'}
}
r#'Defaults env_keep += "PATH HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY http_proxy https_proxy ftp_proxy no_proxy"
agent ALL=(ALL) NOPASSWD:ALL
'# | save /etc/sudoers.d/agent
chmod 0440 /etc/sudoers /etc/sudoers.d/agent
visudo -c
install -d -o agent -g agent /home/agent/workspace

# Shared /usr/local/bin and PNPM_HOME: the directories only, never recursively.
chown root:staff /usr/local/bin
chmod 2775 /usr/local/bin
let pnpm_home = '/usr/local/share/pnpm'
mkdir $"($pnpm_home)/global" $"($pnpm_home)/store"
chown -R root:staff $pnpm_home
chmod 2775 $pnpm_home $"($pnpm_home)/global" $"($pnpm_home)/store"

# Agent CLIs, installed as agent so they can self-update. setpriv rather than sudo: Claude
# Code's installer refuses to run under sudo.
let as_agent = [--reuid=agent --regid=agent --init-groups env HOME=/home/agent USER=agent LOGNAME=agent]
http get https://claude.ai/install.sh | setpriv ...$as_agent bash
http get https://chatgpt.com/codex/install.sh | setpriv ...$as_agent CODEX_NON_INTERACTIVE=1 sh
# The installer runs codex once, leaving arg0 temp dirs. In a lower image layer they
# can't be renamed away (overlayfs EXDEV), so codex warns on every start.
rm -rf /home/agent/.codex/tmp
# Runtime leftovers: Claude Code's socket directory and Node's compile cache.
rm -rf /tmp/cc-socks /tmp/node-compile-cache
# Chained links, so the agents resolve for root too and survive self-updates.
ln -s /home/agent/.local/bin/claude /home/agent/.local/bin/codex /usr/local/bin/
EOF

# Defaults for every context. The locale exists only after the step above. PNPM_HOME matches the
# directory it creates; pnpm's configuration applies to every user and HOME (see "pnpm
# configuration"). Claude Code's Bash tool runs only bash or zsh, so it's pinned to bash rather
# than left to detect agent's nu login shell. Codex falls back to bash on its own.
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANGUAGE=en_US:en \
    GOPATH=/go \
    GOTOOLCHAIN=local \
    BASH_ENV=/etc/devcontainer/env.sh \
    PNPM_HOME=/usr/local/share/pnpm \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/go/bin \
    CLAUDE_CODE_SHELL=/bin/bash
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

# 3. /legal: the notices copied in step 1, then the generated manifest.tsv (see docs/legal.md).
# Its own step, because REVISION changes on every commit.
ARG REVISION
RUN --mount=type=bind,target=/mnt/legal-src --mount=type=bind,from=gh,source=/opt/gh,target=/mnt/gh-legal \
    --mount=type=bind,from=config,target=/mnt/config \
    --mount=type=cache,id=legal-go-mod,target=/var/cache/legal-go-mod,sharing=locked nu /dev/stdin <<'EOF'
bash /mnt/legal-src/scripts/collect-legal.sh /mnt/legal-src/Dockerfile /mnt/config /mnt/gh-legal
# The version checks run node as root, which leaves a compile cache behind.
rm -rf /tmp/node-compile-cache
EOF

LABEL org.opencontainers.image.title="devcontainer" \
      org.opencontainers.image.description="Ubuntu 26.04 LTS image with one pinned toolset for devcontainers, GitHub Actions CI, and agent sandboxes. Copyleft source is attached as OCI referrers; see /legal/SOURCE.md." \
      org.opencontainers.image.licenses="CC0-1.0" \
      org.opencontainers.image.vendor="frithuz" \
      devcontainer.metadata='[{"remoteUser":"agent"}]'
USER agent
WORKDIR /home/agent/workspace
CMD ["/bin/bash"]

# Preflight: never published. Runs the smoke tests (test/smoke.sh) and exports their report and
# exit status, plus the image's manifest.tsv, from which scripts/plan-sources.sh derives the
# source images. A failing test doesn't fail the build: ci.yml fails on the exported status, and
# publish.yml only needs the manifest. Only the files the tests read are mounted, so other changes
# keep the result cached.
FROM image AS preflight-run
# Root keeps the image's ENV, which sudo would reset; the script drops to agent itself. Never
# published, and the default stage below is back to agent.
# hadolint ignore=DL3002
USER root
RUN --mount=type=bind,source=test,target=/mnt/src/test \
    --mount=type=bind,source=Dockerfile,target=/mnt/src/Dockerfile \
    --mount=type=bind,source=scripts/legal-components.yaml,target=/mnt/src/scripts/legal-components.yaml nu /dev/stdin <<'EOF'
mkdir /tmp/out
# complete keeps a failing exit status instead of stopping the script.
let smoke = bash /mnt/src/test/smoke.sh o+e>| complete
print $smoke.stdout
$smoke.stdout | save /tmp/out/smoke.txt
$"($smoke.exit_code)\n" | save /tmp/out/smoke-status
cp /legal/manifest.tsv /tmp/out/manifest.tsv
EOF

FROM scratch AS preflight
COPY --from=preflight-run /tmp/out/ /

# Default target for a plain `docker build`: the image, not the preflight report.
FROM image AS default
