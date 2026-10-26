# syntax=docker/dockerfile:1
# The image already carries Codex, installed as agent so it can self-update.
FROM quay.io/frithuz/devcontainer:build-40265483889@sha256:281aafaf0e23019c282fbd8cbc85240047cc20030893c8d196e4d8aed0a2fbb8
ENV IS_SANDBOX=1 CODEX_HOME=/home/agent/.codex GIT_TERMINAL_PROMPT=0
# sbx launches the entrypoint itself. Clear the image's CMD so bash isn't passed to the agent.
ENTRYPOINT ["codex", "--dangerously-bypass-approvals-and-sandbox"]
CMD []
