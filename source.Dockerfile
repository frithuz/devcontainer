# syntax=docker/dockerfile:1

# Source images (docs/legal.md#source-images): one FROM scratch image per root program and exact
# version, holding /source/<root>/ and /source/SOURCE.json. Build through docker-bake.hcl only:
#   source-plan   runs scripts/plan-sources.sh on the manifests in MANIFESTS (default
#                 out/preflight) and exports out/sources/ (plan.tsv, plans/, sources.hcl).
#   sources       the generated group: docker buildx bake -f docker-bake.hcl -f out/sources/sources.hcl sources
# The bake targets provide the named contexts: apt-keys and config (the Dockerfile's stages),
# manifests, and root-plan (one plans/<tag>/ directory).

# The fetch stage for a plan's kind: apt, git, or bundle.
ARG KIND=git

# Everything runs on the build platform: a source image's layer is the same for every platform,
# so it's fetched once and shared by both platform manifests.
FROM --platform=$BUILDPLATFORM golang:1.27-trixie@sha256:fbb7ae40b62ff8afe31662df570d39b4f5052ac32b90dae8e60d7657a20a74f4 AS go
FROM --platform=$BUILDPLATFORM ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944 AS ubuntu
FROM --platform=$BUILDPLATFORM ghcr.io/jqlang/jq:1.8.2@sha256:b9c68867e5766576263a222e91db3de422d802069c7af70440e667a95344e486 AS jq
FROM --platform=$BUILDPLATFORM ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb AS oras
FROM --platform=$BUILDPLATFORM ghcr.io/nushell/nushell:0.116.1-bookworm@sha256:3de167aad209014bffbc3ed90fc433199b1a835c88a91befe8aa9d9b7db2d428 AS nushell

FROM go AS tools
COPY --link --from=jq /jq /usr/local/bin/jq
COPY --link --from=oras /bin/oras /usr/local/bin/oras
COPY --link --from=nushell /usr/bin/nu /usr/local/bin/nu

# Plan: resolve every root program's exact inputs. Upstream state changes without any build
# input changing, so the bake target never caches this step.
FROM tools AS plan-run
ARG SOURCE_RECIPE_REPOSITORY
ARG SOURCE_RECIPE_REVISION
ARG SOURCE_REUSE
ARG REVISION
ARG REPOSITORY_URL
# config is a named context from docker-bake.hcl (the Dockerfile's config stage).
RUN --mount=type=bind,source=scripts,target=/mnt/scripts --mount=type=bind,from=manifests,target=/mnt/manifests \
    --mount=type=bind,from=config,target=/mnt/config \
    --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/plan.nu,target=/mnt/src/scripts/build/plan.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/plan.nu

FROM scratch AS plan
COPY --from=plan-run /out/ /

# Fetch: one root program, from its plan.
FROM ubuntu AS fetch-apt
# Every apt source is HTTPS (scripts/source-apt.yaml too). The base image's Ubuntu sources use
# plain HTTP and it has no CA certificates, so ca-certificates is fetched trusting the go stage's
# bundle (a pinned image). apt lists live in a cache mount (the deb-src fetches below keep theirs
# in subdirectories of it).
COPY --link --from=nushell /usr/bin/nu /usr/local/bin/nu
RUN --mount=type=cache,id=source-apt-lists,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,from=go,source=/etc/ssl/certs/ca-certificates.crt,target=/tmp/bootstrap-ca.crt \
    --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/apt-bootstrap.nu,target=/mnt/src/scripts/build/apt-bootstrap.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/apt-bootstrap.nu

COPY --link --from=jq /jq /usr/local/bin/jq
# apt-keys is a named context from docker-bake.hcl (the Dockerfile's apt-keys stage).
# hadolint ignore=DL3022
COPY --link --from=apt-keys /keys/ /etc/apt/keyrings/

FROM tools AS fetch-git
FROM tools AS fetch-bundle

# hadolint ignore=DL3006
FROM fetch-${KIND} AS fetch
RUN --mount=type=bind,source=scripts/build-source-image.sh,target=/mnt/build-source-image.sh \
    --mount=type=bind,from=root-plan,target=/mnt/plan \
    --mount=type=cache,id=source-go-mod,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,id=source-apt-lists,target=/var/lib/apt/lists,sharing=locked \
    bash /mnt/build-source-image.sh /mnt/plan/plan.json /out

FROM scratch AS source
COPY --link --chown=0:0 --from=fetch /out/ /
