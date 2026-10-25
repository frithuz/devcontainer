# syntax=docker/dockerfile:1

# Source images (docs/legal.md#source-images): one FROM scratch image per root program and exact
# version, holding /source/<root>/ and /source/SOURCE.json. Build through docker-bake.hcl only:
#   source-plan   runs scripts/plan-sources.sh on the manifests in MANIFESTS (default
#                 out/preflight) and exports out/sources/ (plan.tsv, plans/, sources.hcl).
#   sources       the generated group: docker buildx bake -f docker-bake.hcl -f out/sources/sources.hcl sources
# The bake targets provide the named contexts: apt-keys (the Dockerfile's apt-keys stage),
# manifests, and root-plan (one plans/<tag>/ directory).

# The fetch stage for a plan's kind: apt, git, or bundle.
ARG KIND=git

# Everything runs on the build platform: a source image's layer is the same for every platform,
# so it's fetched once and shared by both platform manifests.
FROM --platform=$BUILDPLATFORM golang:1.27-trixie@sha256:fbb7ae40b62ff8afe31662df570d39b4f5052ac32b90dae8e60d7657a20a74f4 AS go
FROM --platform=$BUILDPLATFORM ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944 AS ubuntu
FROM --platform=$BUILDPLATFORM ghcr.io/jqlang/jq:1.8.2@sha256:b9c68867e5766576263a222e91db3de422d802069c7af70440e667a95344e486 AS jq
FROM --platform=$BUILDPLATFORM ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb AS oras

FROM go AS tools
COPY --link --from=jq /jq /usr/local/bin/jq
COPY --link --from=oras /bin/oras /usr/local/bin/oras

# Plan: resolve every root program's exact inputs. Upstream state changes without any build
# input changing, so the bake target never caches this step.
FROM tools AS plan-run
ARG SOURCE_RECIPE_REPOSITORY
ARG SOURCE_RECIPE_REVISION
ARG SOURCE_REUSE
RUN --mount=type=bind,source=scripts,target=/mnt/scripts --mount=type=bind,from=manifests,target=/mnt/manifests bash <<'EOF'
set -euxo pipefail
mapfile -t manifests < <(find /mnt/manifests -name manifest.tsv | sort)
bash /mnt/scripts/plan-sources.sh --out /out ${SOURCE_REUSE:+--reuse "$SOURCE_REUSE"} "${manifests[@]}"
EOF

FROM scratch AS plan
COPY --from=plan-run /out/ /

# Fetch: one root program, from its plan.
FROM ubuntu AS fetch-apt
# Every apt source is HTTPS (scripts/source-apt.tsv too). The base image's Ubuntu sources use
# plain HTTP and it has no CA certificates, so ca-certificates is fetched trusting the go stage's
# bundle (a pinned image). apt lists live in a cache mount (the deb-src fetches below keep theirs
# in subdirectories of it).
RUN --mount=type=cache,id=source-apt-lists,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,from=go,source=/etc/ssl/certs/ca-certificates.crt,target=/tmp/bootstrap-ca.crt bash <<'EOF'
set -euxo pipefail
sed -i 's|^URIs: http://|URIs: https://|' /etc/apt/sources.list.d/ubuntu.sources
if grep -hE '^[[:space:]]*(URIs:|deb)' /etc/apt/sources.list /etc/apt/sources.list.d/* | grep -q 'http://'; then
  echo "plain HTTP apt source left" >&2
  exit 1
fi
apt-get -o Acquire::https::CAInfo=/tmp/bootstrap-ca.crt update
apt-get -o Acquire::https::CAInfo=/tmp/bootstrap-ca.crt install -y --no-install-recommends ca-certificates
EOF

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
