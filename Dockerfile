# syntax=docker/dockerfile:1

# Source stages: pinned upstream images, multi-arch index digests.
# Keep each reference a plain image:tag@sha256:digest so Dependabot can update it.
# Go is a builder only: the go install stages below start from it, and the /legal step mounts its
# toolchain to read the shipped Go binaries' module info. None of it reaches the image.
FROM golang:1.27-trixie@sha256:c47c3fda018d13d43a6bf5ebac3e5bba8a23a35782aa4faf531afaf47c64c39f AS go
FROM node:26-trixie-slim@sha256:e6bedef217677b276c591795e169840edd9096dbf13f29df8ef8d1856b8820bc AS node
FROM python:3.15-slim-trixie@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928 AS python
FROM ghcr.io/astral-sh/uv:0.13.8@sha256:5cc1805e2426484abca4ad46ea783bab281fdb225fd82d8ce6d66a81254bac85 AS uv
FROM mvdan/shfmt:v3.14.1@sha256:8c06884a35683d8763fba6c0d9484d11a61a96da65f8d497d6f625825a6043f2 AS shfmt
FROM ghcr.io/jqlang/jq:1.8.2@sha256:b9c68867e5766576263a222e91db3de422d802069c7af70440e667a95344e486 AS jq
FROM mikefarah/yq:4.54.3@sha256:7834187596ad56fd5a81436114e0b0b9dd54c91bb43946d1f7145b2be5f9c3d2 AS yq
FROM ghcr.io/pnpm/pnpm:12.21.0@sha256:168feba88e6a1684c99a62cbf4fe361d4e683e2a6c920d3b0acde7e15a28b62d AS pnpm
# Debian 13's official slim image: packages and security updates straight from Debian's archive. The
# image and the stages that compile for it start here.
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS debian
FROM ghcr.io/betterleaks/betterleaks:v1.10.1@sha256:f345c1ac502abc51ec334c3d815ad18a79fb1509555fc4496b2cb88e760681b3 AS betterleaks
FROM ghcr.io/amacneil/dbmate:2.38.1@sha256:b0c8a87bfef4f2819fdb0a68ca357a44d12fb90d23eca695fcfc3b7e159cb1c5 AS dbmate
# adrs, for Architecture Decision Records: upstream's image, built on Debian bookworm, so its binary
# links against an older glibc than the base's. Its Rust dependencies include an MPL-2.0 crate
# (mdbook), which upstream's binary carries the obligation for.
FROM ghcr.io/joshrotenberg/adrs:0.13.0@sha256:7858d9917c73b3d65f54a685d7424d2bf15fcc2da79fc09ff0444bc732aed44c AS adrs

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

# GitHub CLI extensions: gh-stack, for stacked pull requests, and gh-actions-lock, which pins every
# action a repository's workflows use in a lockfile. No images, and their releases publish no
# checksums, so each is upstream's latest release binary, checked against the SHA-256 GitHub reports
# for it. gh-actions-lock's release must be immutable; gh-stack's releases aren't. REFRESH makes
# scheduled builds pick up new releases. setup.sh installs them as agent's gh extensions.
FROM fetch AS gh-extensions
COPY --link --from=jq /jq /usr/local/bin/jq
ARG EXTENSIONS="github/gh-stack github/gh-actions-lock"
ARG IMMUTABLE=github/gh-actions-lock
ARG TARGETARCH
ARG REFRESH
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/gh-extensions.sh,target=/mnt/src/scripts/build/gh-extensions.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/gh-extensions.sh

# apt signing key for Docker's repository, checked against its published fingerprint before the
# final stage trusts it.
FROM fetch AS apt-keys
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/apt-keys.sh,target=/mnt/src/scripts/build/apt-keys.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/apt-keys.sh

# Git, from a scratch artifact published separately (built in frithuz/git), pinned by version and
# digest. Its files sit under /usr, where Debian's git package would put them.
FROM ghcr.io/frithuz/git:2.56.1-1frithuz1@sha256:c0a19004fdd5910e3c8f5132ccef845b89fe737251144e514104db631b1c6631 AS git

# jv, a JSON Schema validator, for the data files below: a builder only, not shipped in the image.
# No upstream image publishes it, so it's built at a pinned version (bumped by hand); Go verifies
# the module against the checksum database.
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
# SHA256_ value together. The binary links against glibc (2.39 or newer at 0.24.1).
FROM fetch AS sampo
ARG VERSION=0.24.1
ARG SHA256_AMD64=56ac1065ba26efccd032e8c2ab594e1405ad70f56758c42ccb206f41b25c319b
ARG SHA256_ARM64=edf379465c3d38079effa8e0ec0faa5b935b2de085a8b41f389576d069d8f5c0
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

# ast-grep and hyperfine: no upstream images, and their releases publish no checksums. Their release
# archives, pinned by SHA-256 per architecture like Sampo's, because each one's Rust dependencies
# include an MPL-2.0 crate (option-ext in ast-grep, colored in hyperfine), which upstream's binary
# carries the obligation for. ast-grep's archive has no LICENSE, so it comes from the release tag,
# pinned too. Bumped by hand: VERSION and every SHA256_ value together. Both link against glibc
# (2.34 or newer for ast-grep at 0.51.2, 2.18 for hyperfine at 2.0.0).
FROM fetch AS ast-grep
ARG VERSION=0.51.2
ARG SHA256_AMD64=40604c21c38d4c7581c56bdddeef277c56bf3c0113620aa96e78ae87e82366df
ARG SHA256_ARM64=c3ab2bd43959db28621dc1551c13ea5fe5db4c1fc7b18086dade6b65042c78d0
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

# Rust: the official image's toolchain, pinned to a minor line, plus rustfmt, clippy,
# rust-analyzer, and the standard library's source, which its minimal profile leaves out. The image
# takes only the toolchain, at /usr/local/rust, without rustup (scripts/build/rust.sh).
FROM rust:1.100-slim-trixie@sha256:e9d95b74296f7126a83ae3d041aeaba1ff4c478f13abc5cc034fcf7c131c3d4a AS rust
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/rust.sh,target=/mnt/src/scripts/build/rust.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/rust.sh

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
COPY --link --from=python /usr/local/ /out/usr/local/
COPY --link --from=rust /opt/rust /out/usr/local/rust
COPY --link --from=node /usr/local/bin/node /out/usr/local/bin/node
COPY --link --chown=0:0 --from=pnpm /opt/pnpm /out/opt/pnpm
COPY --link --chown=0:0 --chmod=0755 --from=uv /uv /uvx /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=shfmt /bin/shfmt /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=jq /jq /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=yq /usr/bin/yq /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=task /opt/task/task /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=sampo /opt/sampo/sampo /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=dnslookup /opt/dnslookup/dnslookup /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=adrs /usr/local/bin/adrs /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=betterleaks /usr/bin/betterleaks /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=dbmate /usr/local/bin/dbmate /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gh /opt/gh/gh /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gh-extensions /opt/gh-extensions/gh-stack/gh-stack /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=gh-extensions /opt/gh-extensions/gh-actions-lock/gh-actions-lock /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=ast-grep /opt/ast-grep/ast-grep /out/usr/local/bin/
COPY --link --chown=0:0 --chmod=0755 --from=hyperfine /opt/hyperfine/hyperfine /out/usr/local/bin/
COPY --link --from=git /out/ /out/
COPY --link --from=apt-keys /keys/ /out/etc/apt/keyrings/
COPY --link rootfs/ /out/
COPY --link LICENSE /out/legal/LICENSE
COPY --link legal/README.md legal/SOURCE.md /out/legal/
COPY --link --from=python /usr/local/lib/python3.15/LICENSE.txt /out/legal/attribution/python/
COPY --link --from=rust /opt/rust-legal/ /out/legal/attribution/rust/
COPY --link --from=jq /COPYING /out/legal/attribution/jq/
COPY --link --from=task /opt/task/LICENSE /opt/task/SOURCE /out/legal/attribution/task/
COPY --link --from=sampo /opt/sampo/LICENSE /opt/sampo/SOURCE /out/legal/attribution/sampo/
COPY --link --from=dnslookup /opt/dnslookup/LICENSE /out/legal/attribution/dnslookup/
COPY --link --from=gh-extensions /opt/gh-extensions/gh-stack/LICENSE /opt/gh-extensions/gh-stack/SOURCE /out/legal/attribution/gh-stack/
COPY --link --from=gh-extensions /opt/gh-extensions/gh-actions-lock/LICENSE /opt/gh-extensions/gh-actions-lock/SOURCE /out/legal/attribution/gh-actions-lock/
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
# Runtime packages, plus the shared libraries the copied Node, Python, and Rust tools link against.
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
ENV BASH_ENV=/etc/devcontainer/env.sh
ENV PNPM_HOME=/usr/local/share/pnpm
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
    --mount=type=bind,from=go,source=/usr/local/go,target=/mnt/go \
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
