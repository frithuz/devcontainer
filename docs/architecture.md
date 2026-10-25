# Architecture

## Repository layout

```text
.
├── LICENSE                     # CC0-1.0 for this project's own files; copied to /legal/LICENSE
├── Dockerfile                  # Multi-stage image definition (stages `image` and `preflight`)
├── docker-bake.hcl             # Bake targets `image`, `preflight`, `config`, `source-plan`, and `source`, shared by CI and local builds
├── .dockerignore
├── rootfs/
│   ├── etc/devcontainer/env.sh # Non-interactive shell environment (BASH_ENV target)
│   └── usr/local/bin/start-dockerd # Starts dockerd for DinD; refuses on macOS VM backends
├── legal/
│   ├── README.md               # Copied to /legal/README.md
│   └── SOURCE.md               # Copied to /legal/SOURCE.md
├── scripts/
│   ├── install-gh.sh           # Scripted installs, one script per tool, only where needed
│   ├── collect-legal.sh        # Gathers notices + records all components and exact source provenance
│   ├── legal-components.yaml   # Copied tools: stage, license, version command, notices (read by collect-legal.sh)
│   ├── source-roots.yaml       # Non-apt root programs that owe source, documented gaps, and license elections
│   ├── source-apt.yaml         # apt repositories: binary URL prefixes → source repository, suites, keyring
│   ├── license-evidence.yaml   # Reviewed license texts added to Go modules so Syft sees every license their notices name
│   ├── schemas/                # JSON Schemas for the YAML files above (editors and the config stage)
│   ├── plan-sources.sh         # Derives the source images an image needs from its manifest.tsv and resolves their inputs
│   ├── build-source-image.sh   # Fetches and verifies one root program's complete source (run by source.Dockerfile)
│   └── build-sources.sh        # Local driver: plan, then build every source image (bake source-plan + sources)
├── source.Dockerfile           # Source images: plan stage, per-kind fetch stages, FROM scratch `source`
├── sandboxes/                  # Docker Sandboxes kits built on the image (used from git, not published)
│   ├── claude/
│   │   ├── claude.yaml         # Kit descriptor (capabilities, network policy, credentials)
│   │   └── claude.dockerfile   # FROM quay.io/frithuz/devcontainer@sha256:... ; ENTRYPOINT ["claude"]
│   └── codex/
│       ├── codex.yaml
│       └── codex.dockerfile
├── test/
│   ├── smoke.sh                # PR preflight checks + tests against the published digest
│   └── runtime.sh              # Checks that need a running container (DinD)
├── .github/
│   ├── dependabot.yml
│   └── workflows/
│       ├── ci.yml              # PRs: lint, preflight via docker/github-builder bake.yml, runtime checks
│       └── publish.yml         # main pushes + schedule: build once to GHCR, test alongside attachment + Quay sync
├── README.md
└── docs/
```

## Dockerfile structure

The Dockerfile has four kinds of stages. The two that are built directly are exposed as Bake targets in `docker-bake.hcl`: **`image`** (the final stage) and **`preflight`**.

### 1. Source stages: pinned upstream images

Each upstream image is declared once, near the top of the file, as a named stage:

```dockerfile
FROM golang:1.x-trixie@sha256:<digest>                    AS go
FROM node:26-trixie-slim@sha256:<digest>                  AS node
FROM python:3.15-slim-trixie@sha256:<digest>              AS python
FROM ghcr.io/astral-sh/uv:<ver>@sha256:<digest>           AS uv
FROM ghcr.io/oras-project/oras:<ver>@sha256:<digest>      AS oras
FROM hadolint/hadolint:v2.x@sha256:<digest>               AS hadolint
FROM mvdan/shfmt:v3.x@sha256:<digest>                     AS shfmt
FROM ghcr.io/betterleaks/betterleaks:v1.x@sha256:<digest> AS betterleaks
# ...
```

Each `FROM` line has to be a plain `image:tag@sha256:digest` with no build args in the reference, because that's the form Dependabot's `docker` ecosystem can parse and update. The tag is there for readability and so Dependabot can find newer versions. The digest is what actually gets pulled.

Digests must be **multi-arch index digests**, not per-platform manifest digests. Otherwise an arm64 build would pull an amd64 binary.

### 2. Builder stages: scripted installs, isolated

Anything that has to be fetched or installed by script, and doesn't need to live in a user's home directory, runs in a throwaway builder stage. The final image receives only `COPY --from=` output.

- `pnpm-dist`: adds the `pn`, `pnpx`, and `pnx` hard links next to the binary from the `pnpm` source stage (see [tooling.md](tooling.md#notes-per-tool)).
- `apt-keys`: fetches the git-core PPA and Docker repository signing keys and checks their fingerprints, so `gnupg` stays out of the final image.
- `gh`: downloads the latest `gh` release tarball and verifies it against the release's published checksums (see [tooling.md](tooling.md#notes-per-tool)).
- `jv`: builds `jv`, a JSON Schema validator, with `go install` at a pinned version (no upstream image publishes it). It's static, and the stage also keeps the module's `LICENSE`. The image ships it for CI systems, and the `config` stage uses it.
- `config`: validates the scripts' data files (`scripts/*.yaml`) against their JSON Schemas in `scripts/schemas/`, rejects duplicate names, and converts them to JSON. `collect-legal.sh` and `plan-sources.sh` read only this output, never the YAML, so a malformed file fails the build before anything uses it. `docker buildx bake config` runs the check on its own and exports the JSON to `out/config/`. Each YAML file names its schema in a `yaml-language-server` comment, so editors with YAML language support complete and check it as you type.

### 3. Final stage (`image`)

```text
FROM ubuntu:26.04@sha256:<digest>
  1. apt: runtime packages (ca-certificates, curl, bash, sudo-rs, openssh-client, less, locales, ...)
     plus the shared libraries the copied Node (libatomic1) and Python link against (see "Binary compatibility"),
     tzdata, netbase, and media-types, and the python3 shim (see "Default PATH")
  2. apt: git from the git-core PPA (latest stable)
  3. apt: Docker Engine from Docker's apt repository (docker-ce, docker-ce-cli,
     docker-buildx-plugin, docker-compose-plugin, containerd.io)
  4. locale-gen en_US.UTF-8, then immediately ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANGUAGE=en_US:en
  5. COPY --from=<source/builder stages> → /usr/local/..., then ldconfig (registers libpython)
  6. COPY rootfs/ → /
  7. symlink every primary command into /usr/local/bin (see "Default PATH")
  8. create GOPATH (/go) as root:staff, group-writable + setgid; `go version` as a build-time sanity check
     (see "Go workspace")
  9. rename the stock `ubuntu` user to `agent` (UID/GID 1000, home /home/agent), add to the `docker` and `staff` groups,
     configure passwordless sudo that keeps PATH (see "sudo configuration")
  10. make /usr/local/bin root:staff, group-writable + setgid (see "Shared /usr/local/bin")
  11. configure pnpm (ENV pnpm_config_*, shared PNPM_HOME) (see "pnpm configuration")
  12. USER agent: run the Claude Code and Codex standalone installers
  13. USER root: symlink /usr/local/bin/{claude,codex} → /home/agent/.local/bin/{claude,codex}
  14. USER root: assemble /legal (root LICENSE → /legal/LICENSE, legal/, image-sourced licenses,
      collect-legal.sh fetching the rest from upstream) (see legal.md)
  15. USER agent, WORKDIR /home/agent/workspace, CMD ["/bin/bash"]
```

apt is used only for what can't be copied in: base OS packages (including `sudo-rs` and `locales`), git, and Docker Engine. All apt installs use `--no-install-recommends`. `/var/lib/apt/lists` is a cache mount shared by the apt steps (one per target architecture), so the lists never reach a layer and `apt-get update` only fetches what changed since the last build. Every apt source is HTTPS: the base image's Ubuntu sources (plain HTTP) are rewritten before the first update. The base image has no CA certificates, so that first update and the `ca-certificates` install trust the CA bundle from the pinned `go` stage. Later steps use the installed store. `source.Dockerfile`'s apt fetch stage does the same.

The agent installers run near the end so refreshing them does not invalidate earlier toolchain copies. A weekly build explicitly invalidates the apt, `gh`, and agent installation layers using a refresh build argument; otherwise unchanged `RUN` instructions can remain cached indefinitely. Other builds may reuse those layers. See [weekly refresh](maintenance.md#workflow).

For pinned standalone binaries such as hadolint and golangci-lint, use `COPY --link --from=<stage>` into stable destinations with fixed ownership and modes. BuildKit can reuse these independent copy layers when earlier apt layers change. Keep refresh arguments out of their source stages and avoid later commands that rewrite those binaries. Confirm destination paths are real directories: `COPY --link` cannot follow destination symlinks from earlier layers. See [Docker's `COPY --link` behavior](https://docs.docker.com/reference/dockerfile/#copy---link).

Copyleft source is published as separate [source images](legal.md#source-images), one per root program and exact version. Reusing a binary copy layer and reusing its source image are independent: both should remain reusable when only unrelated packages change.

### 4. Preflight stage (`preflight`)

`preflight` is built `FROM` the `image` stage for PR CI and local checks and is never published. It **runs `test/smoke.sh`** as `agent` and as root (see [maintenance.md](maintenance.md#preflight-checks-testsmokesh)). A failing check fails the build.

A final `FROM scratch` stage exports the test report and the image's `/legal/manifest.tsv` as local build output (`out/preflight/`, one directory per platform for a multi-platform build). `docker/github-builder` builds with `output: local` and uploads it as a GitHub artifact. CI then runs `scripts/plan-sources.sh --check` on those manifests: it derives every root program that owes source and resolves each one's exact inputs (commit, source package, archives) without building the source images, so a missing upstream source fails the PR.

Publishing builds `image` once and records its digest. It does not build `preflight` first or rely on cache reuse to establish image identity. The complete smoke suite then runs against that published digest on both architectures, while source publication and copying to Quay proceed independently. Source images are built from `source.Dockerfile`, separately from the runtime image, using the image's inventory. Test failures remain visible without blocking synchronization. See [the publish workflow](maintenance.md#workflow).

## Binary compatibility

Binaries copied from upstream images have to run on Ubuntu's glibc. Rules:

- Prefer **statically linked** binaries (most Go tools: hadolint, shfmt, gomplate, yq, jv, golangci-lint, betterleaks, gh, oras; plus uv).
- For dynamically linked tools (Node, Python, git-cliff, pnpm), copy from a **glibc** (Debian-based) image whose glibc is no newer than Ubuntu 26.04's. Never copy dynamic binaries out of Alpine/musl images.
- **Python** needs the most care. The official image builds CPython against Debian's shared libraries, so the final stage must install the Ubuntu packages that provide the same sonames: OpenSSL 3, libffi, SQLite, zlib, bzip2, xz/lzma, readline, ncurses, expat, uuid, and gdbm. The exact package list is taken from the source image (`ldd` on the interpreter and on `lib-dynload/*.so`) during implementation. A missing library doesn't break `python3 --version`; it surfaces only when the matching stdlib module is imported. That's why the smoke test imports them.
- `test/smoke.sh` runs every binary on both architectures in CI, which catches incompatibilities.

## Filesystem conventions

| Path | Contents |
| --- | --- |
| `/usr/local/go` | Go toolchain (copied whole from the `golang` image) |
| `/go` | `GOPATH`: module cache (`pkg/mod`), `src`, and `go install` output (`bin`). `root:staff`, group-writable, setgid |
| `/usr/local/lib/node_modules/npm` | npm, bundled with Node |
| `/usr/local/lib/python3.15`, `/usr/local/lib/libpython3.15.so*`, `/usr/local/include/python3.15` | CPython stdlib, shared library, and headers (copied from the `python` image) |
| `/opt/pnpm` | pnpm standalone binary, its hard-linked aliases, and bundled `dist/` (copied from the `pnpm` image) |
| `/usr/local/share/pnpm` | `PNPM_HOME`: pnpm global packages and content-addressable store. `root:staff`, group-writable, setgid |
| `/usr/local/bin/*` | Standalone tool binaries, plus symlinks to every primary command |
| `/home/agent/.local/share/claude/` | Claude Code versions (owned by `agent` so it can self-update) |
| `/home/agent/.codex/packages/standalone/` | Codex releases (owned by `agent` so it can self-update) |
| `/etc/devcontainer/env.sh` | Environment for non-interactive shells |
| `/legal` | License and notice files for every redistributed component (see [legal.md](legal.md)) |
| `/usr/local/bin/start-dockerd` | Starts the in-container Docker daemon (see [Docker](#docker)) |
| `/var/lib/docker` | Docker daemon state. Expected to be a mounted volume when DinD is used, never a layer of the image |
| `/var/lib/containerd` | Containerd image storage when configured; also requires exclusive mounted storage for DinD |

Platform tools live in system paths and work for any UID. The agent CLIs are the deliberate exception. Their standalone installers install per-user and update in place, so they belong to `agent`.

### Default PATH

GitHub Actions container jobs don't honor a `PATH` set with `ENV`, so **every primary command must resolve under Ubuntu's default `PATH`**:

```text
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Standalone binaries are copied straight into `/usr/local/bin`. Everything else gets a symlink there:

| Command(s) | `/usr/local/bin` symlink target |
| --- | --- |
| `go`, `gofmt` | `/usr/local/go/bin/*` |
| `node` | copied directly |
| `python3`, `python`, `pip3`, `pip`, `python3.15`, `pip3.15` | copied directly with the `python` image's `/usr/local/bin` entries (including its `python` → `python3` symlinks) |
| `npm`, `npx` | `/usr/local/lib/node_modules/npm/bin/*-cli.js` (same layout as the `node` image) |
| `pnpm`, `pn`, `pnpx`, `pnx` | `/opt/pnpm/*` (hard links to one binary) |
| `claude` | `/home/agent/.local/bin/claude` |
| `codex` | `/home/agent/.local/bin/codex` |
| `git`, `docker`, `dockerd`, `containerd` | n/a (apt installs to `/usr/bin`) |

The agent links are deliberately **chained**: `/usr/local/bin/claude` → `~/.local/bin/claude` → the current version. The installers own the inner link and repoint it on each self-update, so the outer link never goes stale. The Codex installer writes absolute targets based on `$HOME` (`/home/agent` at build time), so the chain also resolves for root in CI. Claude Code's link is created by the `claude install` binary rather than by the script, so its form has to be confirmed in a container build. The `env -i` smoke test (see [maintenance.md](maintenance.md#ci-ciyml-on-every-pr)) catches it either way.

The `go` and `gofmt` links are made with `ln -sf /usr/local/go/bin/* /usr/local/bin/`, so any other binary the toolchain ships is linked too.

Ubuntu's own `/usr/bin/python3` isn't installed. Ubuntu's `sudo-rs` depends on `python3:any` (for an apport hook), which would pull in Ubuntu's Python 3.14. To prevent that, the first apt step installs `devcontainer-python3-shim`, a metadata-only local package with `Provides: python3` and `Multi-Arch: allowed`, the form that satisfies a `:any` dependency. It owns no files and its `Provides` is unversioned, so a package that needs Ubuntu's real `python3` (for example `python3-yaml`) still installs it alongside without conflict. If that happens, `/usr/local/bin/python3` still takes precedence, because `/usr/local/bin` comes first on the default `PATH`.

Executables installed with `go install` land in `/go/bin`, which is outside the default `PATH`. That's acceptable: they're the user's own installs, not image-provided commands.

### Go workspace

`GOPATH` is a shared system directory, `/go`, rather than a per-user one. That way `agent` (devcontainers, sandboxes) and root (CI) use the same module cache and `go install` target:

1. Create `/go/src` and `/go/bin`.
2. `chown -R root:staff /go` and `chmod -R 775 /go`, so members of `staff` can write.
3. `chmod 2775` on `/go`, `/go/src`, and `/go/bin`. With setgid, directories Go creates at runtime (for example `/go/pkg/mod`) inherit the `staff` group.
4. Run `go version` as a build-time sanity check that the toolchain and its symlinks work.

`agent` is a member of `staff`, and root needs no group. With the default `022` umask, subdirectories created at runtime keep the `staff` group but aren't group-writable. That's fine for the supported contexts, since each runs as a single user: `agent` or root. Build cache (`GOCACHE`) stays per-user under `$HOME/.cache/go-build`.

### Shared /usr/local/bin

`agent` must be able to run `pnpm add -g`, which links package bins into `/usr/local/bin`. That directory gets the same treatment as `GOPATH`, `root:staff` with mode `2775`, applied to **the directory only, not recursively**. `PNPM_HOME` is handled in [pnpm configuration](#pnpm-configuration).

Never run `chown -R` or `chmod -R` over the copied toolchains (`/usr/local/go`, `/usr/local/lib/python3.15`, ...). Changing ownership in a later layer duplicates every affected file into a new layer, which roughly doubles their size in the image. Where a copied tree must be group-owned, set ownership at copy time with `COPY --chown`.

A side effect: `agent` can overwrite image-provided binaries in `/usr/local/bin` with a global package install. That's accepted, since `agent` already has passwordless root.

### pnpm configuration

pnpm's config file is per-user (`~/.config/pnpm/config.yaml`). A per-user file doesn't survive GitHub Actions, which sets `HOME=/github/home`. So the image sets pnpm's configuration as **`ENV` variables** (`pnpm_config_<setting>`, with dashes as underscores). They apply to every user and every `HOME`, and no `config.yaml` is written:

| `ENV` | Value | Why |
| --- | --- | --- |
| `pnpm_config_global_bin_dir` | `/usr/local/bin` | Global package bins land on the default `PATH` |
| `pnpm_config_global_dir` | `/usr/local/share/pnpm/global` | Shared global packages under `PNPM_HOME`, explicit instead of relying on the default |
| `pnpm_config_store_dir` | `/usr/local/share/pnpm/store` | Shared store, so `agent` and root (CI) reuse each other's downloads |
| `pnpm_config_fetch_retries` | `6` | Registry fetch retry backoff (see below) |
| `pnpm_config_fetch_retry_factor` | `2` | Registry fetch retry backoff (see below) |
| `pnpm_config_fetch_retry_mintimeout` | `3750` | Registry fetch retry backoff (see below) |
| `pnpm_config_fetch_retry_maxtimeout` | `120000` | Registry fetch retry backoff (see below) |
| `pnpm_config_strict_ssl` | `true` | The default, set explicitly so TLS verification can't silently drift off |
| `pnpm_config_prefer_offline` | `true` | Serve from the store first, and hit the network only on a miss |
| `pnpm_config_prefer_frozen_lockfile` | `true` | Skip resolution when the lockfile is current. Global-safe form; plain `frozen-lockfile` is rejected in global config |
| `pnpm_config_verify_store_integrity` | `true` | Keep store integrity verification on |
| `pnpm_config_update_notifier` | `false` | No update nag. pnpm's version comes from the pinned `pnpm` image |

With the fetch-retry values the backoff is 3.75 s, 7.5 s, 15 s, 30 s, 60 s, 120 s, which rides out registry hiccups without hammering the registry.

These rely on two things the first build must confirm: that the installed pnpm version reads `pnpm_config_*` variables, and that GitHub Actions passes non-`PATH` image `ENV` through to steps. The smoke test checks the effective values with `pnpm config get` as `agent`, as root, and with `HOME` pointed at an empty directory.

`PNPM_HOME` (`/usr/local/share/pnpm`) is created by root, so `agent` gets write access the same way as the rest of the shared install targets. Its contents get `chown -R root:staff`, `2775` on directories (setgid, so new files inherit the group), and `g+w` on files. It's small at build time, so recursion is fine here.

## Users

Docker Sandboxes dictates the user model, and the other contexts adapt to it:

- Non-root user **`agent`**, UID/GID **1000**, home **`/home/agent`**, present in `/etc/passwd`, with passwordless `sudo` and membership in the `docker` and `staff` groups (`staff` grants write access to [`GOPATH`](#go-workspace)). The stock Ubuntu `ubuntu` user (UID 1000) is renamed rather than kept alongside. Its supplementary groups (`adm`, `sudo`, `cdrom`, ...) are replaced, not kept, so `agent` belongs only to `docker` and `staff`.
- `sudo` is provided by **[sudo-rs](https://github.com/trifectatechfoundation/sudo-rs)**, the memory-safe Rust implementation that Ubuntu ships as its default `sudo`. The original `sudo` package is not installed. See [sudo configuration](#sudo-configuration).
- The image's default `USER` is `agent`.
- Devcontainers set `remoteUser: agent`.
- CI overrides the user to root (see [usage.md](usage.md#github-actions)). The agent CLIs stay usable as root through the `/usr/local/bin` symlinks.

### sudo configuration

`sudo` has to keep the caller's `PATH`. GitHub Actions rebuilds `PATH` at runtime (including `$GITHUB_PATH` additions), and a command run through `sudo` must resolve the same tools as the caller. Proxy variables have to survive too, so proxied networking keeps working under `sudo`.

sudo-rs ships a `Defaults secure_path` line in `/etc/sudoers`. It overrides `PATH` no matter what `env_keep` says, and a drop-in can't unset it. The user step therefore does all of the following:

1. Deletes the `Defaults secure_path` line from `/etc/sudoers`.
2. Writes `/etc/sudoers.d/agent` (mode `0440`):

   ```text
   Defaults env_keep += "PATH HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY http_proxy https_proxy ftp_proxy no_proxy"
   agent ALL=(ALL) NOPASSWD:ALL
   ```

3. Sets `/etc/sudoers` to mode `0440`. The base image ships it as `0644`, and sudo-rs's `visudo -c` rejects anything but `0440`. This also removes needless world-readability.
4. Runs `visudo -c`, which validates `/etc/sudoers` and every file under its `@includedir`, so a syntax error fails the build instead of locking out `sudo` at runtime.

Dropping `secure_path` gives up no real protection here. Its job is to stop a user-controlled `PATH` from shadowing root's commands, but `agent` already has unrestricted passwordless root.

## Docker

The image ships the full Docker Engine. Ordinary GitHub Actions jobs use the runner's daemon through its mounted socket; dedicated DinD tests and Linux devcontainers can use the image's own server. Having the packages installed doesn't mean a daemon is running:

- **No daemon starts automatically.** There's no `ENTRYPOINT`, and nothing in `BASH_ENV` starts `dockerd`. A context that wants DinD runs `start-dockerd` explicitly.
- **`start-dockerd`** (from `rootfs/`) starts `dockerd` in the background, through `sudo` when not root, and waits for `/var/run/docker.sock` to accept connections. It does nothing if a daemon is already reachable.
- **DinD needs a privileged container** and exclusive volumes for daemon data, including `/var/lib/docker` and `/var/lib/containerd` when used by the configured image store. Each daemon gets its own storage; never reuse a fixed volume name across active devcontainers. The consumer configures these mounts (see [usage.md](usage.md)).
- **The CLI works without the daemon.** `docker`, `docker buildx`, and `docker compose` can target any daemon through a mounted socket or `DOCKER_HOST`.
- **DinD tests must select and verify the local daemon.** They use a dedicated container with no host socket mount, clear inherited remote-daemon selection, and verify the responding daemon belongs to that container. Otherwise `start-dockerd` can correctly return without starting anything, and the test would exercise the host daemon instead.

### Never run DinD on macOS hosts

Running `dockerd` inside a container on a macOS host (Docker Desktop, OrbStack, and similar Linux-VM backends) is **not supported**, because it is known to cause corruption. On macOS, consumers use the host's daemon instead: they mount the host socket and point the image's CLI at it (see [usage.md](usage.md#docker-on-macos-hosts)).

As a safety net, `start-dockerd` refuses to start when the kernel identifies a macOS VM backend (`uname -r` containing `linuxkit` or `orbstack`). The check is best-effort. Backends such as Colima run stock kernels it can't recognize, so the rule itself, not the check, is the guarantee.

## Environment

| Variable | Value | Why |
| --- | --- | --- |
| `PATH` | system defaults + `/go/bin` | A convenience for `go install`ed tools only. GitHub Actions ignores it, so no image-provided command may depend on it |
| `GOPATH` | `/go` | Shared by `agent` and root; see [Go workspace](#go-workspace). Must be declared with `ENV` before the step that creates it |
| `PNPM_HOME` | `/usr/local/share/pnpm` | Shared pnpm home; see [pnpm configuration](#pnpm-configuration) |
| `GOTOOLCHAIN` | `local` | Stops Go from silently downloading a different toolchain |
| `BASH_ENV` | `/etc/devcontainer/env.sh` | Loaded by every non-interactive bash, which is how `sbx` launches agents. Must stay idempotent and quiet |
| `LANG` / `LC_ALL` | `en_US.UTF-8` | Predictable UTF-8 locale. Generated at build with `locale-gen en_US.UTF-8` from the `locales` package |
| `LANGUAGE` | `en_US:en` | Message-translation fallback order for gettext-based tools |

The three locale variables are set in a single `ENV` placed directly after `locale-gen`, so every later build step already runs under the generated locale. Setting them before the locale exists would make each later step warn that the locale can't be set.

Rule of thumb: anything that must hold in every context goes in `ENV`, and anything that needs shell logic goes in `env.sh`. Nothing should depend on `.bashrc` or `/etc/profile`, and command lookup must never depend on `PATH` additions.

Both agent installers append a `PATH` line to a shell profile in `agent`'s home. That line is harmless and is left in place, but nothing relies on it.

No credentials, tokens, or user config are baked into the image, ever. Auth always comes from the consuming context at runtime.

## Docker Sandboxes contract

From [Use your own Linux image](https://docs.docker.com/ai/sandboxes/customize/author/base-images/#use-your-own-linux-image). The image must meet all of these:

- [x] `agent` user, UID 1000, home `/home/agent`, in `/etc/passwd`, `USER agent`
- [x] `curl`, `git`, CA certificates
- [x] Executable `/bin/sh` and `/bin/bash`
- [x] `ENTRYPOINT` or `CMD` set (the base image uses `CMD ["/bin/bash"]`; each kit sets its agent as `ENTRYPOINT`)
- [x] Absolute `WORKDIR` (`/home/agent/workspace`), used when no workspace is mounted
- [x] Persistent environment through `BASH_ENV`, not profiles
- [x] Agent tools installed as `agent`, not as root (root installs land in `/root/`)

The `com.docker.sandbox/sbx@1` capability is declared in each kit descriptor under `sandboxes/`, not on the image. The upstream conformance tests check the image against it.

## Image metadata

The image carries OCI labels (`org.opencontainers.image.source`, `.revision`, `.version`, `.created`, `.licenses`) and a `devcontainer.metadata` label. The latter holds the default `remoteUser: agent` and similar settings, so a consumer's `devcontainer.json` can stay minimal.

Set `org.opencontainers.image.licenses="CC0-1.0"` for the project's own contribution, following Docker's repository-license convention. Use the same value for corresponding manifest/index annotations. Bundled software retains its individual licenses, recorded in `/legal`; see [legal metadata](legal.md#packaging-and-metadata) for the rationale and scope.
