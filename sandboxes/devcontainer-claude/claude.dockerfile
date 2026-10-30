# syntax=docker/dockerfile:1
# Claude Code on the devcontainer image, which carries no agents. The agent is Docker's Claude
# Code mixin (docker/sandbox-kit-spec, examples/claude-mixin), pinned by version and digest.
# scripts/update-kits.sh rewrites both pins and the descriptor's provides together.
ARG IMAGE=quay.io/frithuz/devcontainer:build-41144881393@sha256:ead09b7d6307e9ed7039bbfa939b03314376e9ddd2fb1f016138e8b3a9b8e089
ARG MIXIN=docker.io/docker/sbx-kit-claude-mixin:2.1.314@sha256:23c168d27d2a4779163bd2d7427e2ab6ce45adab5f99b2dd6da9cb6f2991cbbe

FROM ${MIXIN} AS mixin
FROM ${IMAGE} AS base

# The mixin ships no notices. legal.sh verifies the binary against Anthropic's release manifest,
# adds Anthropic's terms, and appends Claude Code's row to the image's manifest. It runs on the
# build platform, reading the target's binary and manifest as files, so building the kit still
# runs nothing on the target platform. A kit's build context is its own directory, so the script
# runs without scripts/build/run.sh.
FROM --platform=$BUILDPLATFORM ${IMAGE} AS legal
ARG MIXIN
ARG TARGETARCH
COPY --from=mixin /usr/local/bin/claude /mnt/claude
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
      org.opencontainers.image.title="Claude Code (devcontainer)" \
      org.opencontainers.image.description="Claude Code on the frithuz devcontainer image" \
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
# Only the binary: the mixin's Docker Desktop hook isn't registered by this kit's settings. No
# --link into the image's directories: a linked layer carries its own copy of each parent, which
# would replace the shared /usr/local/bin's group and mode
# (docs/architecture.md#shared-writable-directories).
COPY --from=mixin /usr/local/bin/claude /usr/local/bin/claude
COPY --from=legal /out/ /
# The image runs as root; sbx needs the agent user.
USER agent
# The binary is root-owned, so it can't update itself: a new version comes with a new mixin pin.
# Claude Code's Bash tool runs only bash or zsh, so it's pinned to bash rather than left to
# detection.
ENV IS_SANDBOX=1 DISABLE_AUTOUPDATER=1 CLAUDE_CODE_SHELL=/bin/bash
# sbx launches the entrypoint itself. Clear the image's CMD so bash isn't passed to the agent.
ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
CMD []
