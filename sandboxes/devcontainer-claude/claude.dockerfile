# syntax=docker/dockerfile:1
# The image already carries Claude Code, installed as agent so it can self-update.
FROM quay.io/frithuz/devcontainer:build-40358718718@sha256:1598abcab8bf07ec98e0edea830d77177cf82d1c3cfff9027dd02a769cdd2454
# sbx starts the image's Docker engine, in a privileged container, only when the image
# carries this label, as Docker's own sandbox templates do. Without it dockerd fails to start.
LABEL com.docker.sandboxes.start-docker="true"
# The image runs as root; sbx needs the agent user.
USER agent
ENV IS_SANDBOX=1
# sbx launches the entrypoint itself. Clear the image's CMD so bash isn't passed to the agent.
ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
CMD []
