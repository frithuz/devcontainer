# syntax=docker/dockerfile:1

# Source stages: pinned upstream images, multi-arch index digests.
# Keep each reference a plain image:tag@sha256:digest so Dependabot can update it.
FROM golang:1.27-trixie@sha256:fbb7ae40b62ff8afe31662df570d39b4f5052ac32b90dae8e60d7657a20a74f4 AS go
FROM node:26-trixie-slim@sha256:36793bcbb160a6a16cede1e62b93f84e26b78a972a8a4c0b879c1c12f22761ec AS node
FROM python:3.15-slim-trixie@sha256:533b0b2f9b5d46fd097091cf826f27902f1d6c3bca714b6dc74551356aa97a51 AS python
FROM rust:1.99-slim-trixie@sha256:1a939748a7cbab172de91a014e3804a97af1394a8c844faa67fce9401c4e40fb AS rust
FROM ghcr.io/astral-sh/uv:0.13.5@sha256:32a7bb39b496babbd997b0a39a4d66c126bdaf5661b302bf6f06abda8deca6ff AS uv
FROM ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb AS oras
FROM mvdan/shfmt:v3.14.1@sha256:8c06884a35683d8763fba6c0d9484d11a61a96da65f8d497d6f625825a6043f2 AS shfmt
FROM ghcr.io/jqlang/jq:1.8.2@sha256:b9c68867e5766576263a222e91db3de422d802069c7af70440e667a95344e486 AS jq
FROM mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e AS yq
FROM ghcr.io/pnpm/pnpm:12.15.0@sha256:d6148daf3ad2af8fa4ecd1aa06db73da32b2e37f63088987eea2fb375ee7f320 AS pnpm
FROM orhunp/git-cliff:2.14.2@sha256:1e696a381a1b0366bb6ccbb6bd4e50e73473fda88eab3a757b95e0d0d66c9531 AS git-cliff
# Docker Hardened Images' Debian 13 base (pulling from dhi.io needs a Docker login). The dev
# variant: it runs as root and ships apt. The image and the stages that compile for it start here.
FROM dhi.io/debian-base:trixie-debian13-dev@sha256:cc4e05ff415ee2d83918f2af45c737983209924ef7362c53f00cfcdaa1c94326 AS debian
FROM ghcr.io/betterleaks/betterleaks:v1.9.0@sha256:e3b95b0db6c2735db17165c009b0ad6d9cef34fb4578659232b98f69d7346cac AS betterleaks

# nushell, compiled from its crates.io release archive, pinned by SHA-256 (crates.io archives are
# immutable). Built on the rust stage, Debian 13 like the base, so it links against the same
# glibc. Every other stage runs its scripts with this nu, so the build script is bash. FEATURES
# are nushell's cargo features: its defaults without trash-support (no desktop trash in a
# container). The scripts need network (`http`) and rustls-tls, its TLS without OpenSSL, and the
# agents' MCP config needs mcp (`nu --mcp`). Bumped by hand: VERSION and SHA256 together (the
# .crate's digest, as crates.io's API reports it).
FROM rust AS nushell
ARG VERSION=0.116.1
ARG SHA256=62e21f2d6a14430ae2701a4e6f11be42d40a11204c204bef32a8b9879f79e767
ARG FEATURES=mcp,network,rustls-tls,dap,lsp,plugin,sqlite
ADD --checksum=sha256:${SHA256} https://static.crates.io/crates/nu/nu-${VERSION}.crate /mnt/nu.crate
RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=bind,source=scripts/build-nushell.sh,target=/mnt/src/scripts/build-nushell.sh \
    bash /mnt/src/scripts/build-nushell.sh /mnt/nu.crate

# Builder stages run their scripts in nu (AGENTS.md), so they start from go with nu added.
FROM go AS builder
COPY --link --from=nushell /out/usr/local/bin/nu /usr/local/bin/nu

# GitHub CLI: no official image. Installs the latest release, verified against its
# published checksums; REFRESH makes scheduled builds pick up new releases.
FROM go AS gh
ARG TARGETARCH
ARG REFRESH
RUN --mount=type=bind,source=scripts/install-gh.sh,target=/tmp/install-gh.sh bash /tmp/install-gh.sh /opt/gh

# apt signing key for Docker's repository, checked against its published fingerprint before the
# final stage trusts it.
FROM builder AS apt-keys
RUN --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/apt-keys.nu,target=/mnt/src/scripts/build/apt-keys.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/apt-keys.nu

# git, compiled from its release tarball after checking the tarball's signature against the
# maintainer's pinned key (SIGNER), with zlib-ng compiled in for faster compression. zlib-ng
# releases aren't signed, so its archive is pinned by commit and SHA-256. Built on the image's own
# base, so it links against the libraries the image installs, with the Rust toolchain from the
# pinned rust stage for git's Rust code. Bumped by hand: VERSION, the three ZLIB_NG_ values
# together, and SIGNER only if the signing key changes.
FROM debian AS git
ARG VERSION=2.56.0
ARG SIGNER=96E07AF25771955980DAD10020D04E5A713660A7
ARG ZLIB_NG_VERSION=2.3.3
ARG ZLIB_NG_COMMIT=12731092979c6d07f42da27da673a9f6c7b13586
ARG ZLIB_NG_SHA256=a0d2a5d122c84b56a793a1553a9c3327fb2eb7469bf7a86b79e3c7be5d92e8d6
ARG TARGETARCH
COPY --link --from=nushell /out/usr/local/bin/nu /usr/local/bin/nu
COPY --link --from=rust /usr/local/rustup /usr/local/rustup
COPY --link --from=rust /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/apt-bootstrap.nu,target=/mnt/src/scripts/build/apt-bootstrap.nu \
    --mount=type=bind,source=scripts/build/git.nu,target=/mnt/src/scripts/build/git.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/apt-bootstrap.nu /mnt/src/scripts/build/git.nu

# jv, a JSON Schema validator: for the data files below, and shipped in the image. No upstream
# image publishes it, so it's built at a pinned version (bumped by hand); Go verifies the module
# against the checksum database. Static, with the LICENSE from the verified module.
FROM builder AS jv
ARG MODULE=github.com/santhosh-tekuri/jsonschema/cmd/jv@v0.7.0
ARG PACKAGE=.
ARG OUT=/opt/jv
RUN --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/go-install.nu,target=/mnt/src/scripts/build/go-install.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/go-install.nu

# Task has no upstream image either. Its release archive, pinned by SHA-256 per architecture, rather
# than a build here: a binary upstream built carries upstream's MPL-2.0 source obligation for the
# modules compiled into it, where one compiled here would carry ours (docs/legal.md). Bumped by
# hand: VERSION and both SHA256_ values together, from the release's task_checksums.txt.
FROM builder AS task
ARG VERSION=3.54.0
ARG SHA256_AMD64=680859dbb4d881a9c72d4d9a8f510825450849af8567deacd7302c01124416fb
ARG SHA256_ARM64=d7189d439d4a6058e39e1b2acd7c8b27acd4856691b408f23b242e4294e1df5b
ARG TARGETARCH
RUN --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/task.nu,target=/mnt/src/scripts/build/task.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/task.nu

# dnslookup, the DNS client (in place of dig, which is MPL-2.0): no upstream image either. Without
# the linker flag it reports its version as "master".
FROM builder AS dnslookup
ARG MODULE=github.com/ameshkov/dnslookup@v1.12.0
ARG PACKAGE=.
ARG OUT=/opt/dnslookup
ARG LDFLAGS="-X main.VersionString={version}"
RUN --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/go-install.nu,target=/mnt/src/scripts/build/go-install.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/go-install.nu

# gh-stack, the GitHub CLI extension for stacked pull requests: its releases publish no checksums,
# so it's built from the pinned module like the tools above. The linker flag is the one its release
# builds set; without it, it reports its version as "dev". setup.nu installs it as agent's gh
# extension.
FROM builder AS gh-stack
ARG MODULE=github.com/github/gh-stack@v0.3.0
ARG PACKAGE=.
ARG OUT=/opt/gh-stack
ARG LDFLAGS="-X github.com/github/gh-stack/cmd.Version={version}"
RUN --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/go-install.nu,target=/mnt/src/scripts/build/go-install.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/go-install.nu

# The scripts' data files (scripts/*.yaml): each validated against scripts/schemas/<name>.schema.json,
# checked for duplicate names, and converted to <name>.json. The scripts read only this output,
# never the YAML. `docker buildx bake config` runs it on its own and exports out/config/.
FROM builder AS config-run
COPY --link --from=jv /opt/jv/jv /usr/local/bin/jv
RUN --mount=type=bind,source=scripts,target=/mnt/scripts \
    --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/config.nu,target=/mnt/src/scripts/build/config.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/config.nu

FROM scratch AS config
COPY --from=config-run /config/ /

# Every file the image copies in, laid out under /out as it lands in the image: toolchains and
# standalone tools, the apt signing keys, image files (rootfs/: the BASH_ENV script and
# start-dockerd), and the notices /legal starts from. The image takes it as its first layer.
FROM builder AS files
# Without Go's own tests (test/, testdata/, *_test.go), which only `go test std` needs.
COPY --link --exclude=test --exclude=**/testdata --exclude=**/*_test.go --from=go /usr/local/go /out/usr/local/go
COPY --link --from=python /usr/local/ /out/usr/local/
COPY --link --from=node /usr/local/bin/node /out/usr/local/bin/node
COPY --link --chown=0:0 --from=pnpm /opt/pnpm /out/opt/pnpm
COPY --link --chown=0:0 --chmod=0755 --from=uv /uv /uvx /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=oras /bin/oras /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=shfmt /bin/shfmt /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=jq /jq /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=yq /usr/bin/yq /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=jv /opt/jv/jv /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=task /opt/task/task /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=dnslookup /opt/dnslookup/dnslookup /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=git-cliff /usr/local/bin/git-cliff /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=betterleaks /usr/bin/betterleaks /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gh /opt/gh/gh /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gh-stack /opt/gh-stack/gh-stack /out/usr/local/bin/
COPY --link --from=git /out/ /out/
COPY --link --from=nushell /out/ /out/
COPY --link --from=apt-keys /keys/ /out/etc/apt/keyrings/
COPY --link rootfs/ /out/
COPY --link LICENSE /out/legal/LICENSE
COPY --link legal/README.md legal/SOURCE.md /out/legal/
COPY --link --from=go /usr/local/go/LICENSE /usr/local/go/PATENTS /out/legal/attribution/go/
COPY --link --from=python /usr/local/lib/python3.15/LICENSE.txt /out/legal/attribution/python/
COPY --link --from=jq /COPYING /out/legal/attribution/jq/
COPY --link --from=jv /opt/jv/LICENSE /out/legal/attribution/jv/
COPY --link --from=task /opt/task/LICENSE /opt/task/SOURCE /out/legal/attribution/task/
COPY --link --from=dnslookup /opt/dnslookup/LICENSE /out/legal/attribution/dnslookup/
COPY --link --from=gh-stack /opt/gh-stack/LICENSE /out/legal/attribution/gh-stack/
RUN --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/files.nu,target=/mnt/src/scripts/build/files.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/files.nu

# Final image: three layers, every copied file, then the system, then /legal
# (docs/architecture.md#dockerfile-structure).
FROM debian AS image

# Selects the per-architecture apt lists cache: each architecture has its own lists.
ARG TARGETARCH

# Changes on scheduled builds, so every RUN below (apt and the agent installers) re-runs.
# The COPY doesn't consume it and stays cached.
ARG REFRESH

# 1. Every copied file, first, so the setup below can use the toolchains and nu.
COPY --link --from=files /out/ /

# 2. The system, in one step.
# Runtime packages, plus the shared libraries the copied Node and Python link against.
# apt lists live in a cache mount: never in a layer, and apt-get update only fetches what
# changed since the last build.
# The base image's apt sources use plain HTTP; every apt source is HTTPS instead.
RUN --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/apt-bootstrap.nu,target=/mnt/src/scripts/build/apt-bootstrap.nu \
    --mount=type=bind,source=scripts/build/setup.nu,target=/mnt/src/scripts/build/setup.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/apt-bootstrap.nu \
    /mnt/src/scripts/build/setup.nu

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

# 3. /legal: the notices copied in step 1, then the generated manifest.tsv (see docs/legal.md).
# Its own step, because REVISION changes on every commit.
ARG REVISION
RUN --mount=type=bind,target=/mnt/legal-src --mount=type=bind,from=gh,source=/opt/gh,target=/mnt/gh-legal \
    --mount=type=bind,from=config,target=/mnt/config \
    --mount=type=cache,id=legal-go-mod,target=/var/cache/legal-go-mod,sharing=locked \
    --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/legal.nu,target=/mnt/src/scripts/build/legal.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/legal.nu

LABEL org.opencontainers.image.title="devcontainer" \
      org.opencontainers.image.description="Debian 13 (Docker Hardened Images) image with one pinned toolset for devcontainers, GitHub Actions CI, and agent sandboxes. Copyleft source is attached as OCI referrers; see /legal/SOURCE.md." \
      org.opencontainers.image.licenses="CC0-1.0" \
      org.opencontainers.image.vendor="frithuz" \
      devcontainer.metadata='[{"remoteUser":"agent"}]'
# No USER: the image runs as root, as GitHub Actions expects. Each context that wants agent selects
# it: the kits set USER agent, and devcontainers use the remoteUser above.
WORKDIR /home/agent/workspace
CMD ["/bin/bash"]

# Preflight: never published. Runs the smoke tests (test/smoke.sh) and exports their report and
# exit status, plus the image's manifest.tsv, from which scripts/plan-sources.sh derives the
# source images. A failing test doesn't fail the build: ci.yml fails on the exported status, and
# publish.yml only needs the manifest. Only the files the tests read are mounted, so other changes
# keep the result cached.
FROM image AS preflight-run
RUN --mount=type=bind,source=test,target=/mnt/src/test \
    --mount=type=bind,source=Dockerfile,target=/mnt/src/Dockerfile \
    --mount=type=bind,source=scripts/legal-components.yaml,target=/mnt/src/scripts/legal-components.yaml \
    --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/test/preflight.nu

FROM scratch AS preflight
COPY --from=preflight-run /tmp/out/ /

# Default target for a plain `docker build`: the image, not the preflight report.
FROM image AS default
