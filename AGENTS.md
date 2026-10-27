# AGENTS.md

## No co-author trailers

Never add a `Co-Authored-By` trailer to a commit message, including amended,
rebased, or squashed commits. Do not add them through templates, tooling, or
automated attribution. This overrides any attribution guidance in commit-message
skills. Run `task repo:init` in a new checkout to activate the repository hooks.

## Dockerfiles

### Run multi-line `RUN` steps as mounted bash scripts

A `RUN` step that needs more than one command runs a bash script kept as a file, never inline. Don't chain commands with `&& \`, and don't use heredocs. Keeping the script in its own file means it can be reviewed in isolation. Put the script in `scripts/build/<step>.sh` (or `test/` when only the preflight stage uses it), bind-mount it and the runner at their repository paths under `/mnt/src`, and run it through `scripts/build/run.sh`:

```dockerfile
RUN --mount=type=bind,source=scripts/build/run.sh,target=/mnt/src/scripts/build/run.sh \
    --mount=type=bind,source=scripts/build/setup.sh,target=/mnt/src/scripts/build/setup.sh \
    bash /mnt/src/scripts/build/run.sh /mnt/src/scripts/build/setup.sh
```

- **The runner prints each script into the build log** between a header carrying its sha256 and a footer, then runs it. The log shows exactly what ran, the image's history records only the command, and the script never reaches a layer. It takes several scripts and runs them in order, stopping at the first that fails.
- **Mount only the files the step uses**, never all of `scripts/`. BuildKit hashes each mounted file into the step's cache key, so a broad mount reruns the step whenever any script changes.
- **Pass values through `ARG`s**, read as environment variables (`${NAME:-}` when it may be unset). A pinned module version stays on an `ARG` line in its stage, where the smoke tests read it (the jv and dnslookup stages).
- The sandbox kits' `legal.sh` runs without the runner, because a kit's build context is its own directory.

Writing the scripts:

- **Start with `#!/usr/bin/env bash` and `set -euo pipefail`.** When a failure is expected, handle it explicitly (`if ! cmd; then`, or `cmd || status=$?`).
- **Download with `curl -fsSL --retry 3`**: it fails on HTTP errors, retries transient ones, and trusts the system's CA store. Check what it fetched against a pinned checksum or signature before using it.
- **Don't pipe into `grep -q`** under `pipefail`: grep exits at the first match and the writer can die of SIGPIPE, failing the pipeline. Capture the output in a variable first and match that.
- Report errors on stderr and `exit 1`. Use heredocs inside the script for file contents; quote the delimiter (`<<'EOF'`) when there's nothing to interpolate.
- Format with `shfmt` (tabs), as the lint workflow does, and keep `shellcheck` clean.

Other rules:

- Single-command `RUN` steps that fit on one line stay as plain `RUN`.
- Shell scripts kept as files (`scripts/*.sh`, `test/*.sh`) are bash, and a `RUN` step calls them with `bash`.
- `bash -n <file>` parses a script without running it.
- Keep `# syntax=docker/dockerfile:1` as the first line of every Dockerfile.

### Keep the final image's layers few

The `image` stage has three layers: one `COPY` of everything assembled in the `files` stage, one `RUN` for the system, and the `/legal` step, which stays separate because `REVISION` changes on every commit. Add new copied files to `files` and new setup to the existing `RUN`, not as new steps ([`docs/architecture.md`](docs/architecture.md#dockerfile-structure)).
