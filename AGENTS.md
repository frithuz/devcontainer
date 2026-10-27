# AGENTS.md

## No co-author trailers

Never add a `Co-Authored-By` trailer to a commit message, including amended,
rebased, or squashed commits. Do not add them through templates, tooling, or
automated attribution. This overrides any attribution guidance in commit-message
skills. Run `task repo:init` in a new checkout to activate the repository hooks.

## Dockerfiles

### Run multi-line `RUN` steps as mounted nu scripts

A `RUN` step that needs more than one command runs a nu script kept as a file, never inline. Don't chain commands with `&& \`, and don't use heredocs. Put the script in `scripts/build/<step>.nu` (or `test/` when only the preflight stage uses it), bind-mount it and the runner at their repository paths under `/mnt/src`, and run it through `scripts/build/run.nu`:

```dockerfile
RUN --mount=type=bind,source=scripts/build/run.nu,target=/mnt/src/scripts/build/run.nu \
    --mount=type=bind,source=scripts/build/setup.nu,target=/mnt/src/scripts/build/setup.nu \
    nu /mnt/src/scripts/build/run.nu /mnt/src/scripts/build/setup.nu
```

- **The runner prints each script into the build log** between a header carrying its sha256 and a footer, then runs it. The log shows exactly what ran, the image's history records only the command, and the script never reaches a layer. It takes several scripts and runs them in order, stopping at the first that fails.
- **Mount only the files the step uses**, never all of `scripts/`. BuildKit hashes each mounted file into the step's cache key, so a broad mount reruns the step whenever any script changes.
- **Pass values through `ARG`s**, read as `$env.NAME` (`$env.NAME? | default ''` when unset). A pinned module version stays on an `ARG` line in its stage, where the smoke tests read it (the jv, task, and dnslookup stages).
- **nu has to be in the stage.** Copy it from the `nushell` stage, which compiles it (`COPY --link --from=nushell /out/usr/local/bin/nu /usr/local/bin/nu`), or start from the `builder` stage, which already has it. Never install it another way. The `nushell` stage itself is the exception to these rules: it builds nu, so its build script is bash (`scripts/build-nushell.sh`). The sandbox kits' `legal.nu` runs without the runner, because a kit's build context is its own directory.

Writing the scripts:

- **No error preamble.** nu stops the script when an external command exits non-zero, anywhere in a pipeline, so there's no `set -e` or `pipefail` to add. When a failure is expected, wrap the command in `complete` (`let result = cmd o+e>| complete`) and check `$result.exit_code`.
- **Prefix an external command with `^` when nu has a builtin of the same name** (`ls`, `cp`, `mkdir`, `rm`, ...) and you need the external one's flags or output. `false` and `true` are boolean literals in nu: call `^false` to run the command.
- **Never `open` and `save` the same file in one pipeline.** nu streams, so `save --force` truncates the file while `open` is still reading it, the way `cat f > f` does. Bind the new contents with `let` first, then save them.
- **Use nu for the logic**: reading files (`open`), downloads (`http get`, not curl; it fails on HTTP errors and trusts the system's CA store), filtering (`where`), string building (`$"..."`), and errors (`error make`). Call external tools (apt-get, dpkg, usermod) for what nu can't do. Use raw strings (`r#'...'#`) for file contents without interpolation.

Other rules:

- Single-command `RUN` steps that fit on one line stay as plain `RUN`.
- Shell scripts kept as files (`scripts/*.sh`, `test/*.sh`) are bash, and a `RUN` step calls them with `bash`.
- nu parses a whole script before running any of it, so a syntax error fails the step before it changes anything. `nu-check <file>` parses one without running it.
- Keep `# syntax=docker/dockerfile:1` as the first line of every Dockerfile.

### Keep the final image's layers few

The `image` stage has three layers: one `COPY` of everything assembled in the `files` stage, one `RUN` for the system, and the `/legal` step, which stays separate because `REVISION` changes on every commit. Add new copied files to `files` and new setup to the existing `RUN`, not as new steps ([`docs/architecture.md`](docs/architecture.md#dockerfile-structure)).
