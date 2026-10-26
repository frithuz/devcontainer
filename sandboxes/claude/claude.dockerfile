# syntax=docker/dockerfile:1
# The image already carries Claude Code, installed as agent so it can self-update.
FROM quay.io/frithuz/devcontainer:build-40348462373@sha256:947de5a9237763ae4be56a6c13d11e2946b7f615a244bdee609a451317364eeb
ENV IS_SANDBOX=1
# sbx launches the entrypoint itself. Clear the image's CMD so bash isn't passed to the agent.
ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
CMD []
