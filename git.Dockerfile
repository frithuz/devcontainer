# syntax=docker/dockerfile:1
ARG VERSION=2.56.0
ARG SHA256=26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3
# Build on the same hardened Debian release as the consumer. The final image is an artifact.
FROM rust:1.99-slim-trixie@sha256:1a939748a7cbab172de91a014e3804a97af1394a8c844faa67fce9401c4e40fb AS rust
FROM dhi.io/debian-base:trixie-debian13-dev@sha256:7995f6739e5ad75cbd57d9356f7d7c83d43dd957682b6a000f32ff95b441a9b6 AS debian

FROM debian AS git
ARG VERSION
ARG SHA256
ARG REVISION
ARG REPOSITORY_URL
ARG SIGNER=96E07AF25771955980DAD10020D04E5A713660A7
ARG ZLIB_NG_VERSION=2.3.3
ARG ZLIB_NG_COMMIT=12731092979c6d07f42da27da673a9f6c7b13586
ARG ZLIB_NG_SHA256=a0d2a5d122c84b56a793a1553a9c3327fb2eb7469bf7a86b79e3c7be5d92e8d6
ARG TARGETARCH
COPY --link --from=rust /usr/local/rustup /usr/local/rustup
COPY --link --from=rust /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/apt-bootstrap.sh,target=/mnt/src/scripts/build/apt-bootstrap.sh \
    --mount=type=bind,source=scripts/build/git.sh,target=/mnt/src/scripts/build/git.sh \
    --mount=type=bind,source=git.Dockerfile,target=/mnt/src/git.Dockerfile \
    --mount=type=bind,source=scripts/build/git-artifact.sh,target=/mnt/src/scripts/build/git-artifact.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/apt-bootstrap.sh /mnt/src/scripts/build/git.sh /mnt/src/scripts/build/git-artifact.sh

FROM scratch AS artifact
ARG VERSION
ARG SHA256
ARG REVISION
ARG REPOSITORY_URL
LABEL org.opencontainers.image.title="Git build artifact" \
    org.opencontainers.image.version=$VERSION \
    org.opencontainers.image.source=$REPOSITORY_URL \
    org.opencontainers.image.revision=$REVISION \
    dev.frithuz.git.source-sha256=$SHA256
COPY --from=git /out/ /out/
