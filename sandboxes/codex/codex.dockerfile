# syntax=docker/dockerfile:1
# The image already carries Codex, installed as agent so it can self-update.
FROM quay.io/frithuz/devcontainer:build-40348462373@sha256:947de5a9237763ae4be56a6c13d11e2946b7f615a244bdee609a451317364eeb
ENV IS_SANDBOX=1 CODEX_HOME=/home/agent/.codex GIT_TERMINAL_PROMPT=0
# sbx launches the entrypoint itself. Clear the image's CMD so bash isn't passed to the agent.
ENTRYPOINT ["codex", "--dangerously-bypass-approvals-and-sandbox"]
CMD []
