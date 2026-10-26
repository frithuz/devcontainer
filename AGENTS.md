# AGENTS.md

## No co-author trailers

Never add a `Co-Authored-By` trailer to a commit message, including amended,
rebased, or squashed commits. Do not add them through templates, tooling, or
automated attribution. This overrides any attribution guidance in commit-message
skills. Run `task repo:init` in a new checkout to activate the repository hooks.

## Dockerfiles

### Prefer nu heredocs for multi-line `RUN` steps

Write any `RUN` step that spans more than one line as a heredoc, and run it with nu. Don't chain commands with `&& \` across lines, and don't rely on the default `/bin/sh`. Every heredoc uses this form:

```dockerfile
RUN nu /dev/stdin <<'EOF'
...
EOF
```

- **Name `/dev/stdin` as the script.** Bare `nu` starts its interactive REPL, which refuses to run without a terminal, so `RUN nu <<'EOF'` fails before running anything.
- **nu has to be in the stage.** Copy it from the pinned `nushell` stage (`COPY --link --from=nushell /usr/bin/nu /usr/local/bin/nu`), or start from the `builder` stage, which already has it. Never install it another way.
- **No error preamble.** nu stops the script when an external command exits non-zero, anywhere in a pipeline, so there's no `set -e` or `pipefail` to add. When a failure is expected, wrap the command in `complete` (`let result = cmd o+e>| complete`) and check `$result.exit_code`.
- **Always quote the delimiter (`'EOF'`).** Then nu, not the Dockerfile parser, reads every `$`. `ARG` and `ENV` values arrive as environment variables: read them as `$env.NAME`, or `$env.NAME? | default ''` when they may be unset.
- **Prefix an external command with `^` when nu has a builtin of the same name** (`ls`, `cp`, `mkdir`, `rm`, ...) and you need the external one's flags or output. `false` and `true` are boolean literals in nu: call `^false` to run the command.
- **Never `open` and `save` the same file in one pipeline.** nu streams, so `save --force` truncates the file while `open` is still reading it, the way `cat f > f` does. Bind the new contents with `let` first, then save them.
- **Use nu for the logic**: reading files (`open`), downloads (`http get`, not curl; it fails on HTTP errors and trusts the system's CA store), filtering (`where`), string building (`$"..."`), and errors (`error make`). Call external tools (apt-get, dpkg, usermod) for what nu can't do. Use raw strings (`r#'...'#`) for file contents without interpolation.

Do:

```dockerfile
RUN nu /dev/stdin <<'EOF'
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
- Shell scripts kept as files (`scripts/*.sh`, `test/*.sh`) are bash, and a `RUN` step calls them with `bash`.
- hadolint doesn't lint a heredoc's body when the `RUN` line names an interpreter, so it checks neither nu nor bash steps. nu parses the whole script before running any of it, so a syntax error fails the step before it changes anything.
- Heredocs require BuildKit's Dockerfile syntax. Keep `# syntax=docker/dockerfile:1` as the first line of every Dockerfile.

### Keep the final image's layers few

The `image` stage has three layers: one `COPY` of everything assembled in the `files` stage, one `RUN` for the system and the agents, and the `/legal` step, which stays separate because `REVISION` changes on every commit. Add new copied files to `files` and new setup to the existing `RUN`, not as new steps ([`docs/architecture.md`](docs/architecture.md#dockerfile-structure)).

## Docker

- Never start `dockerd` (or run `start-dockerd`) inside the container on a macOS host. Docker-in-Docker on macOS causes corruption. If you can't tell what the host is, assume macOS and don't start it.
- When a Docker daemon is needed on macOS, use the host's daemon through a mounted socket. Details are in [`docs/usage.md`](docs/usage.md#docker-on-macos-hosts).
