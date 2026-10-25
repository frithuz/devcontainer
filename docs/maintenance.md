# Maintenance

## Dependabot

`.github/dependabot.yml` covers three ecosystems:

| Ecosystem | Directories | What it updates |
| --- | --- | --- |
| `docker` | `/`, `/sandboxes/*` | Every `FROM image:tag@sha256:digest` in the `Dockerfile` (base + all source stages), plus the kit Dockerfiles' reference to this image |
| `npm` | `/tools` | pnpm (`package.json` + lockfile) |
| `github-actions` | `/` | Actions in `.github/workflows/`, pinned by commit SHA |

Expectations:

- **Weekly schedule.**
- **Groups.** Lint tools are grouped (hadolint, shfmt, golangci-lint, betterleaks). Go, Node, and Python are kept **ungrouped**, so a language bump always gets its own reviewable PR. Pre-release tags (`-rc`, `a`/`b` releases) are ignored.
- **Major versions** of dependencies (Go and Python minor lines count as major here, as do Node major releases and Ubuntu LTS bases) get separate PRs and require a human merge. Patch and digest-only updates can be auto-merged once CI passes.
- **Commit messages** use Conventional Commit prefixes (`build(deps): ...`).

## Updates Dependabot can't handle

| Item | Mechanism |
| --- | --- |
| `gh` version + checksums | A scheduled workflow checks the latest `cli/cli` release and opens a PR that updates the `ARG`s and SHA-256 sums |
| git (PPA) | Not pinned. A scheduled weekly rebuild picks up new PPA releases |
| Ubuntu apt packages | Same as git: refreshed by the scheduled rebuild |
| Docker Engine packages | Same as git: refreshed from Docker's apt repository by the scheduled rebuild |
| Vendored license files | A scheduled job compares them against upstream at the pinned version and opens an issue on drift ([legal.md](legal.md#enforcement)) |
| Claude Code, Codex | Not pinned by design. The latest version is installed on each rebuild, and the agents self-update at runtime |

If the `gh` check workflow becomes a burden, switching to Renovate (its regex managers can track it) is an option. For now the decision is to stay on Dependabot.

## Build definitions

Both workflows build through **[`docker/github-builder`](https://github.com/docker/github-builder)'s reusable `bake.yml`**, pinned by commit SHA (Dependabot's `github-actions` ecosystem keeps it current). Targets come from `docker-bake.hcl`, so PR CI and publishing build exactly the same definitions.

`bake.yml` builds each platform on its own native runner (`ubuntu-26.04` and `ubuntu-26.04-arm`). It can't hand an image back to the calling workflow: `output` is either `image`, pushed to a registry, or `local`, a filesystem export. In-build checks run in the `preflight` build ([architecture.md](architecture.md#4-preflight-stage-preflight)). Checks that need a running container run against the GHCR image before promotion to Quay ([Publishing](#workflow)).

## CI (`ci.yml`, on every PR)

| Job | How | What |
| --- | --- | --- |
| `lint` | Plain job | `hadolint` on all Dockerfiles, `shfmt -d` on shell scripts, `actionlint` (if added), `betterleaks` over the repo |
| `preflight` | `bake.yml`, `target: preflight`, `output: local`, `cache: true` | Builds both architectures natively, runs the [preflight checks](#preflight-checks-testsmokesh) in the build, and builds the source bundles. That catches upstream fetch breakage on the PR itself |
| `runtime` | Plain job: `docker buildx bake image --load` (amd64) | Runs `test/runtime.sh` against the loaded image: a privileged DinD container runs `start-dockerd`, then `docker run --rm hello-world`, a `docker buildx build` of a trivial Dockerfile, and `docker compose version` |

The GitHub Actions `container:` check needs an image in a registry, so it runs in `publish.yml` against the GHCR image, before promotion to Quay (see below).

### Preflight checks (`test/smoke.sh`)

These run inside the `preflight` build on both architectures, as both `agent` and root:

- **Commands and toolchains.** Runs under `env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`. That proves every primary command resolves without the image's `ENV PATH`. It runs every tool's `--version` and fails if any tool is missing or can't execute. Pinned tools also fail on an unexpected version; agent CLIs are checked for presence only. It runs as both `agent` and root, so the chained agent symlinks are verified for both. For Python, it also imports every stdlib module backed by a shared library (`ssl`, `ctypes`, `sqlite3`, `zlib`, `bz2`, `lzma`, `readline`, `curses`, `pyexpat`, `uuid`, `dbm.gnu`), which catches missing runtime libraries that `--version` would miss. For pnpm, it checks that `pnpm config get global-bin-dir` is `/usr/local/bin`, `pnpm config get prefer-offline` is `true`, and `pnpm store path` is under `/usr/local/share/pnpm` (as `agent`, as root, and with `HOME` set to an empty directory), and that `agent` can `pnpm add -g` a small package whose bin then resolves from `/usr/local/bin`. It also checks that `uv python find` resolves to `/usr/local/bin/python3` without downloading anything.
- **Sandbox contract and system setup:** `id agent` reports UID 1000 with home `/home/agent`, the default user is `agent`, `/bin/sh` and `/bin/bash` exist, `curl` and `git` are present, `BASH_ENV` resolves, `claude`/`codex` resolve on `PATH` in a non-interactive `bash -c`, `sudo --version` reports sudo-rs, `sudo -n true` succeeds as `agent` (passwordless), `visudo -c` passes, `sudo env` reports the caller's `PATH` unchanged (including a directory prepended at runtime) and keeps proxy variables, `agent` is in the `docker` and `staff` groups, `/go`, `/go/src`, and `/go/bin` are `root:staff` with mode `2775`, `go version` runs as both `agent` and root, `agent` can `go install` a module into `/go/bin`, `locale -a` lists `en_US.utf8`, and `locale` reports `LANG`/`LC_ALL` as `en_US.UTF-8` and `LANGUAGE` as `en_US:en` without warnings.
- **Attribution:** every non-apt inventory component has its `/legal/attribution` entry (see [legal.md](legal.md#enforcement)).

## Publishing (`publish.yml`)

Images are published to two registries:

| Registry | Role |
| --- | --- |
| **`quay.io/frithuz/devcontainer`** | **Source of truth.** Gets tags only after an image passes `verify` and has its source attached |
| **`ghcr.io/<owner>/devcontainer`** | **Mirror.** `bake.yml` builds and pushes here first. Gives GitHub Actions consumers fast in-network pulls ([integrations/ghcr.md](integrations/ghcr.md)) |

Both carry the same tags, digests, signatures, and source artifacts. There are no versioned releases. Images are published continuously, and tags use only Docker-native forms:

| Tag | Published by | Meaning |
| --- | --- | --- |
| `:main` | Every push to `main` | Tip of `main`. Moves often |
| `:latest` | Every scheduled build | Most recent scheduled build. Moves on the schedule |
| `:YYYYMMDD` | Every scheduled build (`type=schedule,pattern={{date 'YYYYMMDD'}}`) | Immutable snapshot of that day's scheduled build |

**No secrets are stored in GitHub.** GHCR is reached with GitHub's automatic `GITHUB_TOKEN`, and Quay with a short-lived token from OIDC robot federation.

### Workflow

`publish.yml` runs on pushes to `main` and on the schedule. Runs are serialized (`concurrency: publish`, never cancelling in-progress runs), so tags and rollbacks never interleave.

| Job | How | What |
| --- | --- | --- |
| `preflight` | `bake.yml`, `target: preflight`, `output: local`, `artifact-upload: true`, `cache: true`, `cache-mode: max`, explicit `cache-scope` | Preflight checks and source bundles. **If it fails, nothing is pushed anywhere** |
| `build` | `bake.yml`, `target: image`, `output: image`, `push: true`, same `cache-scope`, `sbom: true`, `meta-images: ghcr.io/<owner>/devcontainer`, `meta-tags` (rules above), `registry-auths` using `GITHUB_TOKEN` | Builds, pushes, signs, and **tags on GHCR**. Outputs the index `digest` and `meta-json` (the tags it applied) |
| `attach-ghcr` | Plain job, `needs: build` | Runs immediately: checks the source bundles against the pushed image, and attaches them on GHCR ([legal.md](legal.md#publishing)) |
| `verify` | Plain jobs, `needs: build` | Runs the image by GHCR digest as a GitHub Actions `container:` job (as root), plus the `test/runtime.sh` DinD checks |
| `promote` | Plain job, `needs: [build, attach-ghcr, verify]` | Copies the image to Quay with its referrers, confirms it there, then applies the Quay tags |
| `rollback-ghcr` | Plain job, `if: failure()` after `attach-ghcr`, `verify`, or `promote` | Points GHCR's tags back at what Quay has, or deletes the failed version ([integrations/ghcr.md](integrations/ghcr.md#rollback)) |

`promote`, in order:

1. Log in to GHCR with `GITHUB_TOKEN` (`packages: read`) and to Quay with **robot federation** (`id-token: write`, see [integrations/quayio.md](integrations/quayio.md)).
2. Copy the index **by digest, untagged**, from GHCR to `quay.io/frithuz/devcontainer`, with its referrers (`oras cp -r`). That brings `bake.yml`'s signatures and the source artifact attached by `attach-ghcr`. Copying keeps digests, so signatures and attestations stay valid. Confirm the exact `oras cp` invocation for untagged, digest-only destinations during implementation.
3. Confirm on Quay that the source artifact is attached to the index and every platform manifest, through the native Referrers API.
4. Apply the tags from `build`'s `meta-json` to the Quay digest (`oras tag`).

Quay protects an untagged digest-only push with a hidden temporary tag for **one hour** by default, so steps 2–4 must finish within that hour. `promote` only copies, checks, and tags, so it stays short.

- **Shared cache:** both `bake.yml` calls use the same explicit `cache-scope`. It otherwise defaults to the target name, and the targets differ, so they wouldn't share layers. With a cache hit, `build` reuses the exact layers `preflight` tested, including the unpinned ones (apt, git, agent CLIs).
- **Failures:** Quay only ever gains tags for verified, source-attached images. GHCR is briefly ahead of Quay after every `build`. If anything after `build` fails, `rollback-ghcr` brings it back in line with Quay. The workflow fails and opens an issue, and the next run fixes forward.

### Registry and signing

- **GHCR:** `ghcr.io/<owner>/devcontainer`, a **public** package linked to this repository, with the **Admin** Actions role, which rollback and retention deletes need. `bake.yml` pushes with `registry-auths` built from `${{ github.actor }}` and `${{ secrets.GITHUB_TOKEN }}`. That's GitHub's automatic per-run token, not a stored secret. Setup is in [integrations/ghcr.md](integrations/ghcr.md).
- **Quay:** one robot account, `frithuz+promote`, with **Write** on `devcontainer` only. Its only login method is **robot federation**: the robot trusts GitHub's OIDC issuer for this repository's `main` ref, and `promote` exchanges its GitHub OIDC token for a one-hour Quay token. No token is stored. Setup is in [integrations/quayio.md](integrations/quayio.md).
- **Other secrets:** none are needed today. If a job of ours ever needs a credential for a service without OIDC federation, it comes from 1Password through **Workload Identity**, never from a GitHub secret. See [integrations/1password.md](integrations/1password.md) for the setup and its one bootstrap exception.
- **Visibility:** create `frithuz/devcontainer` on Quay as a public repository before the first promote. Quay makes repositories private when a push creates them ([integrations/quayio.md](integrations/quayio.md#2-repository-frithuzdevcontainer)).
- **Attestations:** `bake.yml` attaches SBOM (`sbom: true`) and SLSA provenance. Provenance is `mode=max` automatically, because the source repository is public.
- **Signing:** `bake.yml` signs the per-platform attestation manifests keylessly with cosign, on GHCR. There they're stored through the referrers tag fallback. `promote` copies them to Quay with the image, where they're native referrers. The signing identity is `bake.yml` itself, so verification works the same against either registry. `bake.yml`'s `cosign-verify-commands` output names GHCR, and the workflow summary adds the Quay equivalents.

### Tags and schedule

- **Schedule:** weekly. Each scheduled build picks up new apt packages, git from the PPA, and the latest agent CLIs. `preflight` tests them before anything is pushed, and `verify` before anything reaches Quay.
- **Consumers** should pin `:YYYYMMDD@sha256:<digest>`. Date tags sort as versions, so the consumer's Dependabot proposes newer snapshots. `:latest@sha256:<digest>` also works, but Dependabot can then only bump the digest. Which registry to use is in [usage.md](usage.md#which-registry).
- Only the image is published. Sandbox kits are consumed from git at a commit, not pushed to a registry ([usage.md](usage.md#agent-sandboxes-sbx)).
- Every image in both registries has its copyleft source attached ([legal.md](legal.md#publishing)).
- **Retention** of old `:YYYYMMDD` snapshots is not decided yet. The same policy applies to both registries, and must follow the [legal retention rules](legal.md#retention): source referrers are never deleted before their image.

## Contributor expectations

- **Adding a tool.** If an upstream image with a static binary or glibc-compatible binary exists, add a pinned `FROM` source stage and a `COPY`. Otherwise, justify the scripted install in the PR and add it to [tooling.md](tooling.md). Either way, make sure its command resolves under the default `PATH` (copy into `/usr/local/bin` or add a symlink there), and add it to `test/smoke.sh`, the [tooling.md](tooling.md) inventory, and `/legal/attribution` ([legal.md](legal.md)).
- Never add an unpinned `FROM` or an unchecked download. `curl | sh` is allowed only for the documented agent standalone installers.
- Keep the final stage free of build-only tooling. Fetching belongs in builder stages.
- Don't break the [sandbox contract](architecture.md#docker-sandboxes-contract). User, UID, home, and shell requirements are fixed.
- Use Conventional Commits.
