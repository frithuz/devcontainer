# syntax=docker/dockerfile:1

# Source stages: pinned upstream images, multi-arch index digests.
# Keep each reference a plain image:tag@sha256:digest so Dependabot can update it.
FROM golang:1.27-trixie@sha256:fbb7ae40b62ff8afe31662df570d39b4f5052ac32b90dae8e60d7657a20a74f4 AS go
FROM node:26-trixie-slim@sha256:e4db4c914bf8ad241bd24804fc25d272d89bad97e68cdc8a1414862790a02c39 AS node
FROM python:3.15-slim-trixie@sha256:533b0b2f9b5d46fd097091cf826f27902f1d6c3bca714b6dc74551356aa97a51 AS python
FROM ghcr.io/astral-sh/uv:0.13.7@sha256:96f40d3904aad8d0bd010539001d36c8e2188b981e1334471a90c4a1d93bb490 AS uv
FROM mvdan/shfmt:v3.14.1@sha256:8c06884a35683d8763fba6c0d9484d11a61a96da65f8d497d6f625825a6043f2 AS shfmt
FROM ghcr.io/jqlang/jq:1.8.2@sha256:b9c68867e5766576263a222e91db3de422d802069c7af70440e667a95344e486 AS jq
FROM mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e AS yq
FROM ghcr.io/pnpm/pnpm:12.17.0@sha256:172468925f0ca368313c09867081a43e298eaeb13dee8f7e4356bfad45dd8b15 AS pnpm
FROM orhunp/git-cliff:2.14.2@sha256:1e696a381a1b0366bb6ccbb6bd4e50e73473fda88eab3a757b95e0d0d66c9531 AS git-cliff
# Debian 13's official slim image: packages and security updates straight from Debian's archive. The
# image and the stages that compile for it start here.
FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS debian
FROM ghcr.io/betterleaks/betterleaks:v1.9.0@sha256:e3b95b0db6c2735db17165c009b0ad6d9cef34fb4578659232b98f69d7346cac AS betterleaks
FROM ghcr.io/amacneil/dbmate:2.38.0@sha256:3937d2826e8189ed1f8cd58331f1f0711721ee10ac4c3d5d5f754fbe37e851ff AS dbmate
FROM bufbuild/buf:1.75.0@sha256:adf82c7170be6629ec81dc907921ac1699407cd11c4f7fd7521b13c74152f849 AS buf

# The download tools on the image's base (curl, gpg, unzip), for the stages that fetch and verify
# releases. Nothing from this stage reaches the image but the files those stages produce.
FROM debian AS fetch
ARG TARGETARCH
RUN --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/apt-bootstrap.sh,target=/mnt/src/scripts/build/apt-bootstrap.sh \
    --mount=type=bind,source=scripts/build/fetch.sh,target=/mnt/src/scripts/build/fetch.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/apt-bootstrap.sh /mnt/src/scripts/build/fetch.sh

# GitHub CLI: no official image. Installs the latest release, verified against its
# published checksums; REFRESH makes scheduled builds pick up new releases.
FROM fetch AS gh
ARG TARGETARCH
ARG REFRESH
RUN --mount=type=bind,source=scripts/install-gh.sh,target=/tmp/install-gh.sh bash /tmp/install-gh.sh /opt/gh

# apt signing key for Docker's repository, checked against its published fingerprint before the
# final stage trusts it.
FROM fetch AS apt-keys
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/apt-keys.sh,target=/mnt/src/scripts/build/apt-keys.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/apt-keys.sh

# Git, from a scratch artifact published separately (built in frithuz/git), pinned by version and
# digest.
FROM quay.io/frithuz/git:2.56.0@sha256:e086987497cf2ed1f1777347d5fdc1e85000b1183a5b8d3f919a058f23d6e5dc AS git

# jv, a JSON Schema validator: for the data files below, and shipped in the image. No upstream
# image publishes it, so it's built at a pinned version (bumped by hand); Go verifies the module
# against the checksum database. Static, with the LICENSE from the verified module.
FROM go AS jv
ARG MODULE=github.com/santhosh-tekuri/jsonschema/cmd/jv@v0.7.0
ARG PACKAGE=.
ARG OUT=/opt/jv
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/go-install.sh,target=/mnt/src/scripts/build/go-install.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/go-install.sh

# Task has no upstream image either. Its release archive, pinned by SHA-256 per architecture, rather
# than a build here: a binary upstream built carries upstream's MPL-2.0 source obligation for the
# modules compiled into it, where one compiled here would carry ours (docs/legal.md). Bumped by
# hand: VERSION and both SHA256_ values together, from the release's task_checksums.txt.
FROM fetch AS task
ARG VERSION=3.54.0
ARG SHA256_AMD64=680859dbb4d881a9c72d4d9a8f510825450849af8567deacd7302c01124416fb
ARG SHA256_ARM64=d7189d439d4a6058e39e1b2acd7c8b27acd4856691b408f23b242e4294e1df5b
ARG TARGETARCH
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/task.sh,target=/mnt/src/scripts/build/task.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/task.sh

# Sampo, the changeset-based release tool: no upstream image, and its releases publish no checksums.
# Its release archive, pinned by SHA-256 per architecture like Task's: its Rust dependencies include
# an MPL-2.0 crate (option-ext), which upstream's binary carries the obligation for. The archive has
# no LICENSE, so it comes from the release tag, pinned too. Bumped by hand: VERSION and every
# SHA256_ value together. The binary links against glibc (2.39 or newer at 0.23.0).
FROM fetch AS sampo
ARG VERSION=0.23.0
ARG SHA256_AMD64=d526913cd5283ec18ac280b515916f44cd0c51a3a22dd780ddce791235354ed6
ARG SHA256_ARM64=b7acca5cf6f9591e50ca6bc71c63bf3d63e5c84cd849152c625c350c20cfef7c
ARG SHA256_LICENSE=5af9a8bbcab03013b58c08124e6a23451664d0e9542be98b7672685cdbcb4c4d
ARG TARGETARCH
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/sampo.sh,target=/mnt/src/scripts/build/sampo.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/sampo.sh

# dnslookup, the DNS client (in place of dig, which is MPL-2.0): no upstream image either. Without
# the linker flag it reports its version as "master".
FROM go AS dnslookup
ARG MODULE=github.com/ameshkov/dnslookup@v1.12.0
ARG PACKAGE=.
ARG OUT=/opt/dnslookup
ARG LDFLAGS="-X main.VersionString={version}"
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/go-install.sh,target=/mnt/src/scripts/build/go-install.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/go-install.sh

# gh-stack, the GitHub CLI extension for stacked pull requests: its releases publish no checksums,
# so it's built from the pinned module like the tools above. The linker flag is the one its release
# builds set; without it, it reports its version as "dev". setup.sh installs it as agent's gh
# extension.
FROM go AS gh-stack
ARG MODULE=github.com/github/gh-stack@v0.3.0
ARG PACKAGE=.
ARG OUT=/opt/gh-stack
ARG LDFLAGS="-X github.com/github/gh-stack/cmd.Version={version}"
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/go-install.sh,target=/mnt/src/scripts/build/go-install.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/go-install.sh

# Go's language server, debugger, linter, and vulnerability scanner: no upstream images, so each is
# built from its pinned module like jv.
FROM go AS gopls
ARG MODULE=golang.org/x/tools/gopls@v0.24.0
ARG PACKAGE=.
ARG OUT=/opt/gopls
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/go-install.sh,target=/mnt/src/scripts/build/go-install.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/go-install.sh

FROM go AS delve
ARG MODULE=github.com/go-delve/delve@v1.27.2
ARG PACKAGE=cmd/dlv
ARG OUT=/opt/delve
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/go-install.sh,target=/mnt/src/scripts/build/go-install.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/go-install.sh

# staticcheck is pinned by its module version, not its release name: release 2026.2.2 is v0.8.2.
FROM go AS staticcheck
ARG MODULE=honnef.co/go/tools@v0.8.2
ARG PACKAGE=cmd/staticcheck
ARG OUT=/opt/staticcheck
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/go-install.sh,target=/mnt/src/scripts/build/go-install.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/go-install.sh

FROM go AS govulncheck
ARG MODULE=golang.org/x/vuln@v1.9.0
ARG PACKAGE=cmd/govulncheck
ARG OUT=/opt/govulncheck
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/go-install.sh,target=/mnt/src/scripts/build/go-install.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/go-install.sh

# ast-grep and hyperfine: no upstream images, and their releases publish no checksums. Their release
# archives, pinned by SHA-256 per architecture like Sampo's, because each one's Rust dependencies
# include an MPL-2.0 crate (option-ext in ast-grep, colored in hyperfine), which upstream's binary
# carries the obligation for. ast-grep's archive has no LICENSE, so it comes from the release tag,
# pinned too. Bumped by hand: VERSION and every SHA256_ value together. Both link against glibc
# (2.34 or newer for ast-grep at 0.51.1, 2.18 for hyperfine at 2.0.0).
FROM fetch AS ast-grep
ARG VERSION=0.51.1
ARG SHA256_AMD64=42514f77ae0c8a25d7d32154d31d3e7e16f3ab894f8ce76ce417de234ee49157
ARG SHA256_ARM64=db02fae2d8eace5fc40c55242068882452dd03eab38a1d950d5fd981cf112926
ARG SHA256_LICENSE=81471889c77b2161a3e4dcdb1b2e6ca382e485766132d92d5fe1d7497e7dd2d9
ARG TARGETARCH
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/ast-grep.sh,target=/mnt/src/scripts/build/ast-grep.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/ast-grep.sh

FROM fetch AS hyperfine
ARG VERSION=2.0.0
ARG SHA256_AMD64=ae2beda2ac99c098427e4f755244552daf20e514422889cca6d44421e2d93c87
ARG SHA256_ARM64=f8244d1e17f8da23ee6b3ae2cdc04a6a185a450f6b74e09bff12e498038fcbc9
ARG TARGETARCH
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/hyperfine.sh,target=/mnt/src/scripts/build/hyperfine.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/hyperfine.sh

# Rust: the official image's toolchain, pinned to a minor line like Go, plus rustfmt, clippy,
# rust-analyzer, and the standard library's source, which its minimal profile leaves out. The image
# takes only the toolchain, at /usr/local/rust, without rustup (scripts/build/rust.sh).
FROM rust:1.99-slim-trixie@sha256:7eab7ce19273ce785e0ca7578bdf7bc1fcbae621775a8197379a04c9f6e03cd5 AS rust
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/rust.sh,target=/mnt/src/scripts/build/rust.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/rust.sh

# protoc, compiled from protobuf's release source tarball on the image's base, so it links against
# the image's glibc: upstream's Linux release binary links glibc (LGPL) statically. Abseil, the
# release protobuf pins, is compiled in. Bumped by hand: VERSION and SHA256 together, and
# ABSEIL_VERSION and ABSEIL_SHA256 when protobuf's cmake/dependencies.cmake moves Abseil (the
# build fails until they match).
FROM debian AS protoc
ARG VERSION=36.2
ARG SHA256=3d9642a662d10e68ebae5e53f14dcce5105684212d5078f8e0d47d1ab3ae6b64
ARG ABSEIL_VERSION=20250512.1
ARG ABSEIL_SHA256=9b7a064305e9fd94d124ffa6cc358592eb42b5da588fb4e07d09254aa40086db
ARG TARGETARCH
RUN --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/apt-bootstrap.sh,target=/mnt/src/scripts/build/apt-bootstrap.sh \
    --mount=type=bind,source=scripts/build/protoc.sh,target=/mnt/src/scripts/build/protoc.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/apt-bootstrap.sh /mnt/src/scripts/build/protoc.sh

# The scripts' data files (scripts/*.yaml): each validated against scripts/schemas/<name>.schema.json,
# checked for duplicate names, and converted to <name>.json. The scripts read only this output,
# never the YAML. `docker buildx bake config` runs it on its own and exports out/config/.
FROM debian AS config-run
COPY --link --from=jv /opt/jv/jv /usr/local/bin/jv
COPY --link --from=yq /usr/bin/yq /usr/local/bin/yq
COPY --link --from=jq /jq /usr/local/bin/jq
RUN --mount=type=bind,source=scripts,target=/mnt/scripts \
    --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/config.sh,target=/mnt/src/scripts/build/config.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/config.sh

FROM scratch AS config
COPY --from=config-run /config/ /

# Every file the image copies in, laid out under /out as it lands in the image: toolchains and
# standalone tools, the apt signing keys, image files (rootfs/: the BASH_ENV script and
# start-dockerd), and the notices /legal starts from. The image takes it as its first layer.
FROM debian AS files
# Without Go's own tests (test/, testdata/, *_test.go), which only `go test std` needs.
COPY --link --exclude=test --exclude=**/testdata --exclude=**/*_test.go --from=go /usr/local/go /out/usr/local/go
COPY --link --from=python /usr/local/ /out/usr/local/
COPY --link --from=rust /opt/rust /out/usr/local/rust
COPY --link --from=node /usr/local/bin/node /out/usr/local/bin/node
COPY --link --chown=0:0 --from=pnpm /opt/pnpm /out/opt/pnpm
COPY --link --chown=0:0 --chmod=0755 --from=uv /uv /uvx /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=shfmt /bin/shfmt /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=jq /jq /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=yq /usr/bin/yq /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=jv /opt/jv/jv /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=task /opt/task/task /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=sampo /opt/sampo/sampo /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=dnslookup /opt/dnslookup/dnslookup /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=git-cliff /usr/local/bin/git-cliff /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=betterleaks /usr/bin/betterleaks /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=dbmate /usr/local/bin/dbmate /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gh /opt/gh/gh /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gh-stack /opt/gh-stack/gh-stack /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gopls /opt/gopls/gopls /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=delve /opt/delve/dlv /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=staticcheck /opt/staticcheck/staticcheck /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=govulncheck /opt/govulncheck/govulncheck /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=buf /usr/local/bin/buf /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=ast-grep /opt/ast-grep/ast-grep /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=hyperfine /opt/hyperfine/hyperfine /out/usr/local/bin/
COPY --link --from=git /out/ /out/
COPY --link --from=protoc /out/ /out/
COPY --link --from=apt-keys /keys/ /out/etc/apt/keyrings/
COPY --link rootfs/ /out/
COPY --link LICENSE /out/legal/LICENSE
COPY --link legal/README.md legal/SOURCE.md /out/legal/
COPY --link --from=go /usr/local/go/LICENSE /usr/local/go/PATENTS /out/legal/attribution/go/
COPY --link --from=python /usr/local/lib/python3.15/LICENSE.txt /out/legal/attribution/python/
COPY --link --from=rust /opt/rust-legal/ /out/legal/attribution/rust/
COPY --link --from=jq /COPYING /out/legal/attribution/jq/
COPY --link --from=jv /opt/jv/LICENSE /out/legal/attribution/jv/
COPY --link --from=task /opt/task/LICENSE /opt/task/SOURCE /out/legal/attribution/task/
COPY --link --from=sampo /opt/sampo/LICENSE /opt/sampo/SOURCE /out/legal/attribution/sampo/
COPY --link --from=dnslookup /opt/dnslookup/LICENSE /out/legal/attribution/dnslookup/
COPY --link --from=gh-stack /opt/gh-stack/LICENSE /out/legal/attribution/gh-stack/
COPY --link --from=gopls /opt/gopls/LICENSE /out/legal/attribution/gopls/
COPY --link --from=delve /opt/delve/LICENSE /out/legal/attribution/delve/
COPY --link --from=staticcheck /opt/staticcheck/LICENSE /out/legal/attribution/staticcheck/
COPY --link --from=govulncheck /opt/govulncheck/LICENSE /out/legal/attribution/govulncheck/
COPY --link --from=ast-grep /opt/ast-grep/LICENSE /opt/ast-grep/SOURCE /out/legal/attribution/ast-grep/
COPY --link --from=hyperfine /opt/hyperfine/LICENSE-APACHE /opt/hyperfine/LICENSE-MIT /opt/hyperfine/SOURCE /out/legal/attribution/hyperfine/
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/files.sh,target=/mnt/src/scripts/build/files.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/files.sh

# Final image: three layers, every copied file, then the system, then /legal
# (docs/architecture.md#dockerfile-structure).
FROM debian AS image

# Selects the per-architecture apt lists cache: each architecture has its own lists.
ARG TARGETARCH

# Changes on scheduled builds, so every RUN below (apt and the agent installers) re-runs.
# The COPY doesn't consume it and stays cached.
ARG REFRESH

# 1. Every copied file, first, so the setup below can use the toolchains.
COPY --link --from=files /out/ /

# 2. The system, in one step.
# Runtime packages, plus the shared libraries the copied Node, Python, protoc, and Rust tools link
# against.
# apt lists live in a cache mount: never in a layer, and apt-get update only fetches what
# changed since the last build.
# The base image's apt sources use plain HTTP; every apt source is HTTPS instead.
RUN --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/apt-bootstrap.sh,target=/mnt/src/scripts/build/apt-bootstrap.sh \
    --mount=type=bind,source=scripts/build/setup.sh,target=/mnt/src/scripts/build/setup.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/apt-bootstrap.sh \
    /mnt/src/scripts/build/setup.sh

# Defaults for every context. The locale exists only after the step above. PNPM_HOME matches the
# directory it creates; pnpm's configuration applies to every user and HOME (see "pnpm
# configuration").
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV GOPATH=/go
ENV GOTOOLCHAIN=local
ENV BASH_ENV=/etc/devcontainer/env.sh
ENV PNPM_HOME=/usr/local/share/pnpm
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/go/bin
ENV pnpm_config_global_bin_dir=/usr/local/bin
ENV pnpm_config_global_dir=/usr/local/share/pnpm/global
ENV pnpm_config_store_dir=/usr/local/share/pnpm/store
ENV pnpm_config_fetch_retries=6
ENV pnpm_config_fetch_retry_factor=2
ENV pnpm_config_fetch_retry_mintimeout=3750
ENV pnpm_config_fetch_retry_maxtimeout=120000
ENV pnpm_config_strict_ssl=true
ENV pnpm_config_prefer_offline=true
ENV pnpm_config_prefer_frozen_lockfile=true
ENV pnpm_config_verify_store_integrity=true
ENV pnpm_config_update_notifier=false

# 3. /legal: the notices copied in step 1, then the generated manifest.tsv and source.tsv (see
# docs/legal.md). Its own step, because REVISION changes on every commit.
ARG REVISION
ARG REPOSITORY_URL
RUN --mount=type=bind,target=/mnt/legal-src --mount=type=bind,from=gh,source=/opt/gh,target=/mnt/gh-legal \
    --mount=type=bind,from=config,target=/mnt/config \
    --mount=type=cache,id=legal-go-mod,target=/var/cache/legal-go-mod,sharing=locked \
    --mount=type=cache,id=legal-apt-lists,target=/var/cache/legal-apt-lists,sharing=locked \
    --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/legal.sh,target=/mnt/src/scripts/build/legal.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/legal.sh

LABEL org.opencontainers.image.title="devcontainer" \
      org.opencontainers.image.description="Debian 13 image with one pinned toolset for devcontainers, GitHub Actions CI, and agent sandboxes. Copyleft source locations are listed in /legal/source.tsv; see /legal/SOURCE.md." \
      org.opencontainers.image.licenses="CC0-1.0" \
      org.opencontainers.image.vendor="frithuz" \
      devcontainer.metadata='[{"remoteUser":"agent"}]'
# No USER: the image runs as root, as GitHub Actions expects. Each context that wants agent selects
# it: the kits set USER agent, and devcontainers use the remoteUser above.
WORKDIR /home/agent/workspace
CMD ["/bin/bash"]

# Preflight: never published. Runs the smoke tests (test/smoke.sh) and exports their report and
# exit status, plus the image's manifest.tsv, which publish.yml compares with the published
# image's. A failing test doesn't fail the build: ci.yml fails on the exported status, and
# publish.yml only needs the manifest. Only the files the tests read are mounted, so other changes
# keep the result cached.
FROM image AS preflight-run
RUN --mount=type=bind,source=test,target=/mnt/src/test \
    --mount=type=bind,source=Dockerfile,target=/mnt/src/Dockerfile \
    --mount=type=bind,source=scripts/legal-components.yaml,target=/mnt/src/scripts/legal-components.yaml \
    --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/test/preflight.sh

FROM scratch AS preflight
COPY --from=preflight-run /tmp/out/ /

# Default target for a plain `docker build`: the image, not the preflight report.
FROM image AS default
