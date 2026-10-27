# syntax=docker/dockerfile:1
# The image already carries Claude Code, installed as agent so it can self-update.
FROM quay.io/frithuz/devcontainer:build-40430546333@sha256:5cc0f49c023d7c6f8ff11756e855ab49051f3b8427f1cc1917d1b51d6dbde487
# The image runs as root; sbx needs the agent user.
USER agent
ENV IS_SANDBOX=1
# sbx launches the entrypoint itself. Clear the image's CMD so bash isn't passed to the agent.
ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
CMD []
