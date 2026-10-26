# syntax=docker/dockerfile:1
# The image already carries Codex, installed as agent so it can self-update.
FROM quay.io/frithuz/devcontainer:build-40358718718@sha256:1598abcab8bf07ec98e0edea830d77177cf82d1c3cfff9027dd02a769cdd2454
ENV IS_SANDBOX=1 CODEX_HOME=/home/agent/.codex GIT_TERMINAL_PROMPT=0
# sbx launches the entrypoint itself. Clear the image's CMD so bash isn't passed to the agent.
ENTRYPOINT ["codex", "--dangerously-bypass-approvals-and-sandbox"]
CMD []
