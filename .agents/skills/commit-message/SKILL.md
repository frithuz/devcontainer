---
name: commit-message
description: Write git commit messages in the Go project's style ("pkg: lowercase summary", wrapped body explaining why, issue trailers). Use whenever creating a commit, amending a commit message, squashing, or drafting a commit message or PR title for this repository.
---

# Commit messages (Go style)

Write every commit message the way the Go project does. The reference is the
Go contribution guide's "Commit messages" section
(<https://go.dev/doc/contribute#commit_messages>). The rules below adapt it to
this repository.

## Format

```text
<prefix>: <summary>

<body>

<trailers>
```

### First line

- **Prefix:** the primary path or area the change touches, followed by a colon
  and a space. Use the shortest name that identifies it unambiguously.
- **Summary:** completes the sentence "This change modifies the repo to ___."
  - Starts with a **lowercase** verb (`add`, `fix`, `pin`, `remove`).
  - Is **not** a complete sentence: no trailing period.
  - Use the imperative mood ("add", not "added" or "adds").
- Keep the whole line to about **72 characters** (hard limit 76). It should
  read well in `git log --oneline`.
- No Conventional Commits types (`feat:`, `fix:`, `chore:`), no emoji, no
  scope parentheses.

### Prefix choice for this repository

| Change touches                         | Prefix                          |
| -------------------------------------- | ------------------------------- |
| `Dockerfile`                           | `Dockerfile`                    |
| `docker-bake.hcl`                      | `docker-bake.hcl`               |
| `rootfs/usr/local/bin/start-dockerd`   | `rootfs/start-dockerd`          |
| a script in `scripts/`                 | `scripts/install-gh.sh`, etc.   |
| a sandbox kit                          | `sandboxes/claude`              |
| tests                                  | `test`                          |
| CI workflows                           | `.github/workflows` or `ci.yml` |
| documentation                          | `docs` (or `docs/usage.md`)     |
| agent instructions or skills           | `AGENTS.md`, `.agents`          |

- When a change spans several areas, list them comma-separated
  (`Dockerfile, test: ...`). If that becomes unwieldy, use `all:`.
- Dependency bumps follow the same rule: `Dockerfile: update node to 26.3.0`.

### Body

- Separate from the first line by one blank line.
- Wrap at **72 columns**. Don't wrap URLs, commands, or code blocks.
- Use complete sentences with normal punctuation.
- Explain **why** the change is needed and what it does at a high level: the
  problem, the context, any non-obvious trade-offs. The diff already shows the
  *what*.
- No Markdown headings or bold. Plain text; indented blocks for command
  output or code are fine.
- A body may be omitted only for trivial changes whose summary says it all
  (e.g. fixing a typo).

### Trailers

Trailers always use git trailer syntax: `Token: value`, one per line, in a
single block of their own separated from the body by one blank line. This
differs from upstream Go, which writes `Fixes #123` without a colon. Here,
always include the colon so `git interpret-trailers` and
`git log --format='%(trailers)'` can parse the lines.

- `Fixes: #123` when the commit fully resolves an issue.
- `Updates: #123` when it relates to an issue but doesn't close it.
- Any attribution trailers the environment requires (e.g. `Co-Authored-By:`)
  go after the issue trailers, in the same block.
- One issue per trailer. When a commit touches several issues, repeat the
  trailer once per issue. Never comma-separate issues in one value. For
  `Fixes: #1, #2`, GitHub closes only `#1`, and trailer parsers see one
  value instead of two issues.

  ```text
  Fixes: #1
  Fixes: #2
  Updates: #3
  ```

- Tokens contain no spaces (`Co-Authored-By`, not `Co Authored By`). Keep
  each trailer on one line. Never put a blank line inside the block.

## Examples

```text
Dockerfile: pin hadolint by digest

The hadolint stage referenced a floating v2 tag, so rebuilds could pick
up a new linter release and fail CI without any change in this repo.
Pin it to the current digest so updates arrive through dependabot like
every other source image.
```

```text
rootfs/start-dockerd: refuse to start on macOS VM backends

Running dockerd inside the container on a macOS host corrupts the
image store. Detect the Docker Desktop and OrbStack VM kernels and exit
with an explanation pointing at the host-socket setup in docs/usage.md.

Fixes: #42
```

```text
docs: fix typo in quay.io integration guide
```

## Procedure

1. Run `git diff --staged` (or inspect the changes being committed) and
   `git log --oneline -20` to see what changed and how recent commits are
   prefixed. Match existing prefixes when they exist.
2. Pick the prefix, write the summary, and check its length.
3. Write the body explaining why. Wrap at 72 columns.
4. Add trailers in `Token: value` form. To check them, pipe the message
   through `git interpret-trailers --parse`. Every trailer you wrote should
   come back out.
5. Commit with a heredoc so formatting survives exactly:

   ```bash
   git commit -F - <<'EOF'
   Dockerfile: pin hadolint by digest

   ...
   EOF
   ```

Don't run `git commit` unless the user asked for a commit; if they only
asked for a message, show it instead.
