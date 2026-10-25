# AGENTS.md

## Dockerfiles

### Use bash heredocs for multi-line `RUN` steps

Write any `RUN` step that spans more than one line as a heredoc, and always run it with bash. Don't chain commands with `&& \` across lines, and don't rely on the default `/bin/sh`. Every heredoc uses this form:

```dockerfile
RUN bash <<'EOF'
set -euxo pipefail
...
EOF
```

- **`bash` is required** in the call, so every script is written for one shell and `sh`/`dash` differences never come up.
- **`set -euxo pipefail` is the first line.** A heredoc script doesn't stop on the first error by default the way an `&&` chain does. `pipefail` also catches failures inside pipelines such as `curl ... | tar ...`.
- **Always quote the delimiter (`'EOF'`).** Then bash, not the Dockerfile parser, does every expansion, so `$var` and `$(cmd)` behave the way they would in any bash script. `ARG` and `ENV` values are still available, because Docker passes them to the step as environment variables.

Do:

```dockerfile
RUN bash <<'EOF'
set -euxo pipefail
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl
rm -rf /var/lib/apt/lists/*
EOF
```

Don't:

```dockerfile
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
```

- Single-command `RUN` steps that fit on one line stay as plain `RUN`.
- Heredocs require BuildKit's Dockerfile syntax. Keep `# syntax=docker/dockerfile:1` as the first line of every Dockerfile.

## Docker

- Never start `dockerd` (or run `start-dockerd`) inside the container on a macOS host. Docker-in-Docker on macOS causes corruption. If you can't tell what the host is, assume macOS and don't start it.
- When a Docker daemon is needed on macOS, use the host's daemon through a mounted socket. Details are in [`docs/usage.md`](docs/usage.md#docker-on-macos-hosts).
