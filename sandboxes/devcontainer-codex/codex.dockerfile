# syntax=docker/dockerfile:1
# Codex on the devcontainer image, which carries no agents. The agent is Docker's Codex mixin
# (docker/sandbox-kit-spec, examples/codex-mixin), pinned by version and digest: Codex's release
# package under /opt/codex. scripts/update-kits.sh rewrites both pins and the descriptor's
# provides together.
ARG IMAGE=quay.io/frithuz/devcontainer:build-40619483983@sha256:3924e8f368369c91a113ad2871d78798a4eb2c36b475766eacfff3b3ccdd9163
ARG MIXIN=docker.io/docker/sbx-kit-codex-mixin:0.164.0@sha256:398870e35ac16de575e087e95805e9413624a6887f5c9472d3873053765777b3

FROM ${MIXIN} AS mixin
FROM ${IMAGE} AS base

# The mixin ships no notices. legal.sh adds Codex's and its bundled ripgrep's, and appends their
# rows to the image's manifest. It runs on the build platform, reading the target's package and
# manifest as files, so building the kit still runs nothing on the target platform. A kit's build
# context is its own directory, so the script runs without scripts/build/run.sh.
FROM --platform=$BUILDPLATFORM ${IMAGE} AS legal
ARG MIXIN
ARG TARGETARCH
COPY --from=mixin /opt/codex/codex-package.json /opt/codex/bin/codex /mnt/codex/
COPY --from=base /legal/manifest.tsv /mnt/manifest.tsv
RUN --mount=type=bind,source=legal.sh,target=/mnt/legal.sh bash /mnt/legal.sh

FROM base
ARG IMAGE
ARG MIXIN
ARG MIXIN_TAG=${MIXIN%@*}
# sbx starts the image's Docker engine, in a privileged container, only when the image
# carries this label, as Docker's own sandbox templates do. Without it dockerd fails to start.
# The OCI labels replace the ones inherited from the image, which describe the image itself
# (docs/architecture.md#image-metadata). Title and description match the descriptor's, and
# version and base come from the pins. Only publish-kits.yml knows the kit's commit, so revision
# and documentation are cleared here and set there with --label.
LABEL com.docker.sandboxes.start-docker="true" \
      org.opencontainers.image.title="Codex (devcontainer)" \
      org.opencontainers.image.description="OpenAI Codex on the frithuz devcontainer image" \
      org.opencontainers.image.version="${MIXIN_TAG##*:}" \
      org.opencontainers.image.base.name="${IMAGE%@*}" \
      org.opencontainers.image.base.digest="${IMAGE#*@}" \
      org.opencontainers.image.revision="" \
      org.opencontainers.image.documentation=""
# git's SSH signing-key command for the descriptor's git-ssh-sign group, from Docker's git-ssh-sign
# kit at a pinned commit, unmodified, with the kit repository's Apache-2.0 license.
ADD --checksum=sha256:ce4beaf2a2447073dced16fd69d8b09616b3aebe11efd995587e3c02091d840f --chmod=0755 \
    https://raw.githubusercontent.com/docker/sbx-kits-contrib/44a891f3ac2f4b81a2fc2ce041f20ce5106835fb/git-ssh-sign/files/home/.config/git/ssh-signing-key-command \
    /usr/local/libexec/git-ssh-sign/
ADD --checksum=sha256:4f1dc9feed9d7b1aab4bb0a117f3966aa428799c2ed58cf09a5c049fbdab29d7 --chmod=0644 \
    https://raw.githubusercontent.com/docker/sbx-kits-contrib/44a891f3ac2f4b81a2fc2ce041f20ce5106835fb/LICENSE \
    /legal/attribution/git-ssh-sign/
# The package and its link on PATH, without the voice libraries (GStreamer and GLib, LGPL), which
# need audio devices a sandbox doesn't have. Codex's app server refuses a package without
# codex-resources/bwrap, though the kit runs Codex with its own sandbox off, so the package gets
# a copy of the image's bwrap from Debian's bubblewrap package, whose source the image's source
# covers, instead of the copy Codex vendors. A symlink won't do: Codex rejects links that leave
# the package. The link on PATH is copied with its directory, since copying the link alone copies
# the binary, which then can't find its package. The mixin's profile.d exports and Docker Desktop
# hook aren't copied: the descriptor sets the environment below and registers no hook. No --link
# into the image's directories: a linked layer carries its own copy of each parent, which would
# replace the shared /usr/local/bin's group and mode (docs/architecture.md#shared-writable-directories).
COPY --exclude=codex-resources/voice --exclude=codex-resources/bwrap --from=mixin /opt/codex /opt/codex
COPY --exclude=sbx-codex-hook --from=mixin /usr/local/bin/ /usr/local/bin/
COPY --from=base /usr/bin/bwrap /opt/codex/codex-resources/bwrap
COPY --from=legal /out/ /
# The image runs as root; sbx needs the agent user.
USER agent
ENV IS_SANDBOX=1 CODEX_HOME=/home/agent/.codex GIT_TERMINAL_PROMPT=0
# sbx launches the entrypoint itself. Clear the image's CMD so bash isn't passed to the agent.
ENTRYPOINT ["codex", "--dangerously-bypass-approvals-and-sandbox"]
CMD []
