# Architecture

## Repository layout

- `Dockerfile`, `docker-bake.hcl`: the image and its Bake targets, shared by CI and local builds.
- `rootfs/`: files copied into the image as-is (the `BASH_ENV` script and `start-dockerd`).
- `legal/`, `scripts/`: the committed `/legal` documents, the scripts that collect notices and plan source images, and their schema-validated YAML data.
- `source.Dockerfile`: builds [source images](legal.md#source-images).
- `.github/workflows/`: `lint.yml` (actionlint and zizmor), `publish.yml`, partly implemented ([maintenance.md](maintenance.md#publishing-publishyml)), and `kits.yml`, which keeps the sandbox kits pinned to the latest image ([maintenance.md](maintenance.md#sandbox-kits)).
- `sandboxes/`: Docker Sandboxes kits, one directory per agent ([usage.md](usage.md#agent-sandboxes-sbx)).
- Planned, not yet present: `test/` (smoke and DinD checks), and the CI workflow in `.github/`.

## Dockerfile structure

The Dockerfile has four kinds of stages. The comments in the file cover the details of each step.

**Source stages** declare each upstream image once, as a plain `image:tag@sha256:digest`. Dependabot's `docker` ecosystem can parse only that form, so build args never appear in a reference. Digests must be **multi-arch index digests**. A per-platform digest would make an arm64 build pull an amd64 binary.

**Builder stages** hold anything fetched or built by script that doesn't belong in a user's home: `gh`, `jv`, the pnpm hard links, and the apt signing keys. That keeps `gnupg` and other fetch tooling out of the final image, which receives only `COPY --from=` output. The `config` stage validates `scripts/*.yaml` against their schemas and converts them to JSON. The scripts read only that output, so a malformed data file fails the build before anything uses it.

**The final stage (`image`)** is ordered for cache reuse:

- The stage declares the `REFRESH` build argument before its first `RUN`, so the weekly build, which changes it, re-runs every `RUN` step. That's what refreshes the apt packages and the agent installs. Otherwise an unchanged `RUN` stays cached indefinitely, and rebuilding the pinned base digest doesn't refresh it. apt installs come first.
- Pinned binaries are copied with independent `COPY --link` layers, which stay reusable when the apt layers below them change. Keep `REFRESH` out of their source stages, and don't rewrite those files in later steps. `COPY --link` can't follow a destination symlink from an earlier layer, so destinations must be real directories.
- The agent installers run near the end, so refreshing them doesn't invalidate the toolchain copies.

apt is used only for what can't be copied: base OS packages, git, and Docker Engine. Every apt source is HTTPS. The base image ships plain-HTTP Ubuntu sources and no CA certificates, so the first `apt-get update` trusts the CA bundle from the pinned `go` stage. The apt lists live in a cache mount, so they never reach a layer.

**The `preflight` stage** builds on `image` for PR CI and local checks, and is never published. It runs the smoke tests and exports each platform's `/legal/manifest.tsv`, which source planning starts from. Publishing builds `image` once and tests that exact digest. It never relies on preflight or cache reuse for the image's identity ([maintenance.md](maintenance.md#workflow)). A refresh builds preflight first, only to decide whether the inventory changed ([maintenance.md](maintenance.md#material-changes)).

## Binary compatibility

Copied binaries have to run on Ubuntu's glibc:

- Prefer statically linked binaries. Most of the Go tools and uv are.
- Copy dynamically linked tools (Node, Python, git-cliff, pnpm) only from glibc (Debian-based) images whose glibc is no newer than Ubuntu's. Never copy them from Alpine/musl images.
- **Python** needs the most care. The official image links CPython against Debian's shared libraries, so the final stage installs the Ubuntu packages with the same sonames. A missing library doesn't break `python3 --version`. It shows up only when the matching stdlib module is imported, which is why the smoke tests import each of them.

## Filesystem

Platform tools live in system paths and work for any UID. The agent CLIs are the deliberate exception: their installers install per-user and update in place, so they belong to `agent`.

Docker daemon state (`/var/lib/docker`, `/var/lib/containerd`) must be a mounted volume when DinD is used, never a layer of the image.

### Default PATH

GitHub Actions container jobs ignore a `PATH` set with `ENV`. So **every image-provided command must resolve under Ubuntu's default `PATH`**. Standalone binaries go straight into `/usr/local/bin`, and everything else gets a symlink there.

The agent links are deliberately **chained**: `/usr/local/bin/claude` → `~agent/.local/bin/claude` → the current version. The installers own the inner link and repoint it on each self-update, so the outer link never goes stale, and it resolves for root in CI too.

Ubuntu's own `python3` isn't installed. `sudo-rs` depends on `python3:any` (for an apport hook), which would pull in Ubuntu's Python. A local metadata-only package, `devcontainer-python3-shim`, provides `python3` instead. Its `Provides` is unversioned, so a package that needs Ubuntu's real `python3` can still install it. `/usr/local/bin/python3` would still take precedence on the `PATH`.

`go install` output lands in `/go/bin`, outside the default `PATH`. That's acceptable, because those are the user's own installs, not image-provided commands.

### Shared writable directories

`agent` (devcontainers, sandboxes) and root (CI) share `GOPATH` (`/go`), `PNPM_HOME` (`/usr/local/share/pnpm`), and `/usr/local/bin`, where `pnpm add -g` links bins. All three are `root:staff`, group-writable, and setgid, and `agent` is in `staff`:

- With the default `022` umask, subdirectories created at runtime keep the `staff` group but aren't group-writable. That's fine, because each supported context runs as a single user.
- `/usr/local/bin` gets this **on the directory only**. Never run `chown -R` or `chmod -R` over copied toolchains: changing ownership in a later layer duplicates every affected file into a new layer. Set ownership at copy time with `COPY --chown` instead.
- `agent` can overwrite image binaries in `/usr/local/bin` through a global install. That's accepted, since `agent` already has passwordless root.

`GOCACHE` stays per-user.

### pnpm configuration

pnpm's config file is per-user, and GitHub Actions sets `HOME=/github/home`, so a config file wouldn't apply there. The image sets pnpm's configuration as `pnpm_config_*` **`ENV` variables** instead, which apply to every user and every `HOME`. Notable choices:

- A shared store under `PNPM_HOME`, so `agent` and root reuse each other's downloads, and global bins in `/usr/local/bin`.
- Fetch retries back off from 3.75 s to 120 s, which rides out registry hiccups without hammering the registry.
- `prefer-frozen-lockfile` instead of `frozen-lockfile`, because pnpm rejects the latter in global config.
- `strict-ssl=true` is the default, set explicitly so TLS verification can't silently drift off.

## Users

Docker Sandboxes dictates the user model, and the other contexts adapt to it. The non-root user is **`agent`**, UID/GID 1000, home `/home/agent`, with passwordless `sudo` and membership in `docker` and `staff`. The stock `ubuntu` user (also UID 1000) is renamed rather than kept alongside, and its supplementary groups (`adm`, `sudo`, ...) are dropped. The default `USER` is `agent`. CI overrides it to root ([usage.md](usage.md#github-actions)).

`sudo` is [sudo-rs](https://github.com/trifectatechfoundation/sudo-rs), Ubuntu's default.

### sudo configuration

`sudo` keeps the caller's `PATH` and proxy variables. GitHub Actions rebuilds `PATH` at runtime, and a command run through `sudo` has to resolve the same tools as its caller.

sudo-rs's `Defaults secure_path` in `/etc/sudoers` overrides `PATH` regardless of `env_keep`, and a drop-in can't unset it, so the build deletes that line. That gives up no real protection: `secure_path` stops a user's `PATH` from shadowing root's commands, but `agent` already has unrestricted root. The build also sets `/etc/sudoers` to `0440`, because the base image ships it as `0644` and sudo-rs's `visudo -c` rejects that. `visudo -c` runs at build time, so a syntax error fails the build instead of locking out `sudo`.

## Docker

The image ships the full Docker Engine, but **no daemon starts automatically**: there's no `ENTRYPOINT`, and nothing in `BASH_ENV` starts one. The CLI works against any daemon through a mounted socket or `DOCKER_HOST`. A context that wants DinD runs `start-dockerd`, which does nothing if a daemon is already reachable.

- DinD needs a privileged container and **exclusive** volumes for daemon data. Never share a volume between two active daemons.
- DinD tests must use a container with no host socket mount and verify that the daemon answering belongs to that container. Otherwise `start-dockerd` correctly returns without starting anything, and the test exercises the host daemon instead.

### Never run DinD on macOS hosts

Running `dockerd` inside a container on a macOS host (Docker Desktop, OrbStack, and similar VM backends) is known to cause corruption. Consumers on macOS use the host's daemon through its socket ([usage.md](usage.md#docker-on-macos-hosts)). `start-dockerd` refuses to start when the kernel looks like a macOS VM backend, but the check is best-effort: backends such as Colima run stock kernels it can't recognize. The rule is the guarantee, not the check.

## Environment

Anything that must hold in every context goes in `ENV`. Anything that needs shell logic goes in `/etc/devcontainer/env.sh`, which `BASH_ENV` loads into every non-interactive bash, which is how `sbx` launches agents. It has to stay idempotent and quiet. Nothing may depend on `.bashrc` or `/etc/profile`, or on `PATH` additions for command lookup.

- The `ENV PATH` adds `/go/bin` only as a convenience for `go install`ed tools.
- `GOTOOLCHAIN=local` stops Go from silently downloading a different toolchain.
- The locale `ENV` comes directly after `locale-gen`. Set earlier, every later build step would warn that the locale doesn't exist.

No credentials, tokens, or user config are ever baked into the image. Auth always comes from the consuming context at runtime.

## Docker Sandboxes contract

[Use your own Linux image](https://docs.docker.com/ai/sandboxes/customize/author/base-images/#use-your-own-linux-image) requires:

- [x] `agent` user, UID 1000, home `/home/agent`, in `/etc/passwd`, `USER agent`
- [x] `curl`, `git`, CA certificates
- [x] Executable `/bin/sh` and `/bin/bash`
- [x] `ENTRYPOINT` or `CMD` set (the image uses `CMD ["/bin/bash"]`, and each kit sets its agent as `ENTRYPOINT`)
- [x] Absolute `WORKDIR`, used when no workspace is mounted
- [x] Persistent environment through `BASH_ENV`, not profiles
- [x] Agent tools installed as `agent`, not root

The `com.docker.sandbox/sbx@1` capability is declared in each kit descriptor, not on the image.

## Image metadata

The image carries OCI labels and a `devcontainer.metadata` label with the default `remoteUser: agent`, so a consumer's `devcontainer.json` can stay minimal. The Dockerfile sets the fixed ones (title, description, licenses, vendor). `docker-bake.hcl` adds the ones a build knows, when it's given them: source, revision, a documentation permalink to `docs/usage.md` at the building commit, and the base image's name and digest, which `publish.yml` reads from the image stage's `FROM` pin. The published image index carries the same values as annotations. `org.opencontainers.image.licenses` is `CC0-1.0`, for the project's own contribution only ([legal.md](legal.md#packaging-and-metadata)).
