# syntax=docker/dockerfile:1
# The image already carries Codex, installed as agent so it can self-update.
FROM quay.io/frithuz/devcontainer:build-40358718718@sha256:1598abcab8bf07ec98e0edea830d77177cf82d1c3cfff9027dd02a769cdd2454
# sbx starts the image's Docker engine, in a privileged container, only when the image
# carries this label, as Docker's own sandbox templates do. Without it dockerd fails to start.
LABEL com.docker.sandboxes.start-docker="true"
# git's SSH signing-key command for the descriptor's git-ssh-sign group, from Docker's git-ssh-sign
# kit at a pinned commit, unmodified, with the kit repository's Apache-2.0 license.
ADD --checksum=sha256:ce4beaf2a2447073dced16fd69d8b09616b3aebe11efd995587e3c02091d840f --chmod=0755 \
    https://raw.githubusercontent.com/docker/sbx-kits-contrib/44a891f3ac2f4b81a2fc2ce041f20ce5106835fb/git-ssh-sign/files/home/.config/git/ssh-signing-key-command \
    /usr/local/libexec/git-ssh-sign/
ADD --checksum=sha256:4f1dc9feed9d7b1aab4bb0a117f3966aa428799c2ed58cf09a5c049fbdab29d7 --chmod=0644 \
    https://raw.githubusercontent.com/docker/sbx-kits-contrib/44a891f3ac2f4b81a2fc2ce041f20ce5106835fb/LICENSE \
    /legal/attribution/git-ssh-sign/
# The image runs as root; sbx needs the agent user.
USER agent
ENV IS_SANDBOX=1 CODEX_HOME=/home/agent/.codex GIT_TERMINAL_PROMPT=0
# sbx launches the entrypoint itself. Clear the image's CMD so bash isn't passed to the agent.
ENTRYPOINT ["codex", "--dangerously-bypass-approvals-and-sandbox"]
CMD []
