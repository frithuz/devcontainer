# Architecture

## Repository layout

- `Dockerfile`, `docker-bake.hcl`: the image and its Bake targets, shared by CI and local builds.
- `rootfs/`: files copied into the image as-is (the `BASH_ENV` script and `start-dockerd`).
- `legal/`, `scripts/`: the committed `/legal` documents, the scripts that collect notices and source locations, and their schema-validated YAML data.
- `scripts/build/`: the bash scripts the Dockerfile's `RUN` steps mount and run, through `run.sh`, which prints each one and its sha256 into the build log first.
- `test/`: `smoke.sh`, the smoke tests the `preflight` stage runs through `preflight.sh`, and `runtime.sh`, the DinD checks, run by `ci.yml` against a built image.
- `.github/workflows/`: `lint.yml` (the workflow and repository linters), `ci.yml` (the image checks on PRs), `publish.yml`, partly implemented ([maintenance.md](maintenance.md#publishing-publishyml)), `kits.yml`, which keeps the sandbox kits pinned to the latest image ([maintenance.md](maintenance.md#sandbox-kits)), and `publish-kits.yml`, which publishes them ([maintenance.md](maintenance.md#publishing-the-kits)).
- `sandboxes/`: Docker Sandboxes kits, one `devcontainer-<agent>` directory per agent ([usage.md](usage.md#agent-sandboxes-sbx)).

## Dockerfile structure

The Dockerfile has four kinds of stages. The comments in the file cover the details of each step.

**Source stages** declare each upstream image once, as a plain `image:tag@sha256:digest`. Dependabot's `docker` ecosystem can parse only that form, so build args never appear in a reference. Digests must be **multi-arch index digests**. A per-platform digest would make an arm64 build pull an amd64 binary.

The base is one of them: the `debian` stage pins [Docker Hardened Images](https://docs.docker.com/dhi/)' Debian 13 base, the `-dev` variant (it runs as root and ships apt), pulled from `dhi.io`, which needs a Docker login. The final stage and the stages that compile for it start from it, so they link against the same libraries.

**Builder stages** hold anything fetched or built by script that doesn't belong in a user's home: `gh`, `jv`, `task`, `dnslookup`, and the apt signing key. That keeps `gnupg`, compilers, and other fetch and build tooling out of the final image. Most start from `go`; Git comes from an independently published artifact ([git](#git)). The `config` stage validates `scripts/*.yaml` against their schemas and converts them to JSON. The scripts read only that output, so a malformed data file fails the build before anything uses it.

**The `files` stage** lays out, under `/out`, every file the image copies in: the toolchains and standalone tools, git's `/usr/local` tree, the pnpm hard links, the `/usr/local/bin` symlinks, the apt signing key, `rootfs/`, and the notices `/legal` starts from. Hard links survive because they're copied within one `COPY`.

**The final stage (`image`)** has as few layers as possible, three:

1. `COPY --link --from=files /out/ /`, first, so the setup step can use the toolchains. It doesn't consume `REFRESH`.
2. One `RUN` for the system: apt (base packages and Docker Engine), the locale, the shared directories, and the `agent` user.
3. The `/legal` step. It reads `REVISION`, which changes on every commit, so it stays separate. Merged into step 2, every build would reinstall everything.

The `ENV` instructions sit between steps 2 and 3. They add no layers, and after step 2 the locale they select exists.

The trade-off is cache reuse. Bumping any copied tool, or changing any file `files` copies, invalidates step 2, so apt and the agent installs run again. The stage declares `REFRESH` before step 2, so the weekly build, which changes it, re-runs it too. That's what refreshes the apt packages and the agent installs. Otherwise an unchanged step stays cached indefinitely, and rebuilding the pinned base digest doesn't refresh it. Keep `REFRESH` out of the copied tools' source stages. `COPY --link` can't follow a destination symlink from an earlier layer, so nothing under `/out` may land on one in the base image (`/bin`, `/lib`, and `/sbin` are symlinks in the base).

apt is used only for what can't be copied: base OS packages and Docker Engine. Packages come from Docker's hardened rebuilds (`dhi.io`, `+dhi` versions) where Docker has one, and otherwise from Debian's archive. Every apt source is HTTPS: the base ships plain-HTTP Debian and DHI sources, which `apt-bootstrap.sh` rewrites, and its own CA certificates. The apt lists live in a cache mount, so they never reach a layer.

**The `preflight` stage** builds on `image` for PR CI and local checks, and is never published. It runs the smoke tests and exports their report, and each platform's `/legal/manifest.tsv`. Publishing builds `image` once and tests that exact digest. It never relies on preflight or cache reuse for the image's identity ([maintenance.md](maintenance.md#workflow)). A refresh builds preflight first, only to decide whether the inventory changed ([maintenance.md](maintenance.md#material-changes)).

## Binary compatibility

Copied binaries have to run on the base's glibc (Debian 13's):

- Prefer statically linked binaries. Most of the Go tools and uv are.
- Copy dynamically linked tools (Node, Python, git-cliff, pnpm) only from glibc (Debian-based) images whose glibc is no newer than the base's. Never copy them from Alpine/musl images.
- **Python** needs the most care. The official image links CPython against Debian's shared libraries, so the final stage installs the same packages. A missing library doesn't break `python3 --version`. It shows up only when the matching stdlib module is imported, which is why the smoke tests import each of them.

## git

The standalone `git.Dockerfile` separates Git's release from the devcontainer.
It uses a pinned hardened Debian builder and Rust
toolchain, then copies only `/out` into a scratch artifact. That tree contains
Git, its helpers and templates, attribution, and the exact build recipe. It is
intended for `COPY --from`, not execution as a container: the consumer supplies
the compatible Debian shared libraries and shell. The main Dockerfile pins
`quay.io/frithuz/git` by version and digest and copies its `/out` tree.

`publish-git.yml` watches the standalone recipe and its scripts. It compares
`VERSION` and the release archive's `SHA256` in `git.Dockerfile` with the version
tag's source-checksum annotation on Quay. A missing tag or changed checksum
builds both architectures; matching inputs skip compilation. Registry errors
fail the run. Recipe, toolchain, and zlib-ng changes alone require a manual run
with `force`. The source signature is verified before compilation; the pinned
archive checksum is also checked before the artifact can be exported.

The workflow publishes to GHCR, signs with the existing OpenBao key, then copies
the image and referrers to `quay.io/frithuz/git:<Git version>` and
`registry.frithuz.dev/frithuz/git:<Git version>`. When Quay already has the
matching artifact, the workflow mirrors it to registry.frithuz.dev without
recompiling. A forced rebuild can move that tag; the main Dockerfile pins its
digest too. After publishing a Git release, update that pin to consume it.

Git is compiled from source in `git.Dockerfile` using `scripts/build/git.sh`.
The builder uses the same hardened Debian release as the devcontainer, so its
shared libraries are compatible. Git installs under `/usr/local` with its
built-in commands as symlinks, so the `files` stage copies it as one tree.

**Verified before use.** The release tarball's signature must verify against the maintainer's key, pinned by fingerprint (`SIGNER`). The keyserver's answer must be that key alone, and gpg's `VALIDSIG` must name it as the signing key's primary: a good signature by any other key fails. zlib-ng publishes no signatures (lightweight tags, unsigned commits), so its archive is pinned by commit and SHA-256 instead, and its header must report the pinned version.

**Compiled in.** [zlib-ng](https://github.com/zlib-ng/zlib-ng), statically, in place of zlib: faster compression for clone, fetch, gc, and reading objects. It picks its CPU-specific code at run time, so one build suits every host. git's Rust code is compiled with the toolchain copied from the pinned `rust` stage; it has no crate dependencies, so cargo runs offline.

**Build options:**

- Debian's hardening flags and link-time optimization, from `dpkg-buildflags`. The base drops dpkg's default vendor, and without one `dpkg-buildflags` prints nothing, so the script sets `DEB_VENDOR=Debian`, fails if the flags lack the stack protector or LTO, and checks the linked binary for full RELRO and a stack protector.
- `sysconfdir=/etc`, so the system config stays `/etc/gitconfig`, where `git config --system` (the kits' commit signing) and other tools expect it.
- OpenSSL's accelerated SHA-1 only where git doesn't need collision detection (checksums of files it writes itself); object IDs keep the collision-detecting SHA-1. OpenSSL also provides SHA-256.
- PCRE2 for `git grep -P`; HTTPS through the image's libcurl.
- No Perl, Python, Tcl/Tk, translations, or expat: no `send-email`, `svn`, `p4`, `gitk`, `git-gui`, or WebDAV `http-push`.

**Not tested at build.** git's own test suite and `git subtree`'s don't run: they took too long for every bump. The stage's inputs are pinned, so rebuilding it gives the same git, and a release that misbehaves is tracked down by running its suite locally. zlib-ng's suite, which is quick, still runs before git links it, and a failure fails the stage. The smoke tests check the installed git as they check every tool.

**Client only.** The daemon, `http-backend`, `git-shell`, `imap-send`, `instaweb`, and the scripts that would only report a missing Perl or Python are removed after install. A release that stops shipping one fails the build, so the list stays accurate. `git subtree` is installed from `contrib/`. There are no man pages or shell completion: use `git <command> -h`.

To bump in `git.Dockerfile`: `VERSION` and `SHA256` for git; `ZLIB_NG_VERSION`, `ZLIB_NG_COMMIT`, and `ZLIB_NG_SHA256` together for zlib-ng; `SIGNER` only if git's maintainer changes signing keys. The smoke tests check Git's version against the main Dockerfile's image tag and zlib-ng's against `ZLIB_NG_VERSION` in the recipe shipped inside that artifact. The artifact carries its original recipe and producer commit for [source attribution](legal.md#compiled-components).

## Filesystem

Platform tools live in system paths and work for any UID.

Docker daemon state (`/var/lib/docker`, `/var/lib/containerd`) must be a mounted volume when DinD is used, never a layer of the image.

### Default PATH

GitHub Actions container jobs ignore a `PATH` set with `ENV`. So **every image-provided command must resolve under the default `PATH`**. Standalone binaries go straight into `/usr/local/bin`, and everything else gets a symlink there.

Debian's own `python3` isn't installed, and nothing the image installs depends on it. The copied CPython in `/usr/local/bin` is the image's `python3`. A package installed later that needs Debian's `python3` pulls it in alongside, and `/usr/local/bin/python3` still takes precedence on the `PATH`.

`go install` output lands in `/go/bin`, outside the default `PATH`. That's acceptable, because those are the user's own installs, not image-provided commands.

### Shared writable directories

`agent` (devcontainers, sandboxes) and root (CI) share `GOPATH` (`/go`), `PNPM_HOME` (`/usr/local/share/pnpm`), and `/usr/local/bin`, where `pnpm add -g` links bins. All three are `root:staff`, group-writable, and setgid, and `agent` is in `staff`:

- With the default `022` umask, subdirectories created at runtime keep the `staff` group but aren't group-writable. That's fine, because each supported context runs as a single user.
- `/usr/local/bin` gets this **on the directory only**. Never run `chown -R` or `chmod -R` over copied toolchains: changing ownership in a later layer duplicates every affected file into a new layer. Set ownership at copy time with `COPY --chown` instead, in the `files` stage.
- `agent` can overwrite image binaries in `/usr/local/bin` through a global install. That's accepted, since `agent` already has passwordless root.

`GOCACHE` stays per-user.

### pnpm configuration

pnpm's config file is per-user, and GitHub Actions sets `HOME=/github/home`, so a config file wouldn't apply there. The image sets pnpm's configuration as `pnpm_config_*` **`ENV` variables** instead, which apply to every user and every `HOME`. Notable choices:

- A shared store under `PNPM_HOME`, so `agent` and root reuse each other's downloads, and global bins in `/usr/local/bin`.
- Fetch retries back off from 3.75 s to 120 s, which rides out registry hiccups without hammering the registry.
- `prefer-frozen-lockfile` instead of `frozen-lockfile`, because pnpm rejects the latter in global config.
- `strict-ssl=true` is the default, set explicitly so TLS verification can't silently drift off.

## Users

Docker Sandboxes dictates the user model, and the other contexts adapt to it. The non-root user is **`agent`**, UID/GID 1000, home `/home/agent`, with passwordless `sudo` and membership in `docker` and `staff`. The base has no user at UID 1000, and keeps only the `root`, `nonroot`, `shadow`, and `nobody` accounts, so the build adds the `staff` group (Debian's GID 50) and creates `agent`. It also sets root's login shell to bash: the base's is `/bin/sh`. The image sets no `USER`, so it runs as root, which is what GitHub Actions expects ([usage.md](usage.md#github-actions)). Contexts that run as `agent` select it themselves: each kit's Dockerfile sets `USER agent`, and devcontainers use the `remoteUser` in the image's metadata.

`sudo` is [sudo-rs](https://github.com/trifectatechfoundation/sudo-rs). Debian's package installs it only as `sudo-rs` and `visudo-rs`, so the build links `sudo` and `visudo` to its binaries. The original `sudo` package must never be installed alongside it.

### sudo configuration

`sudo` keeps the caller's `PATH` and proxy variables. GitHub Actions rebuilds `PATH` at runtime, and a command run through `sudo` has to resolve the same tools as its caller.

Debian's sudo-rs ships no `/etc/sudoers`, so the build writes one: `env_reset`, `use_pty`, root's rule, and `@includedir /etc/sudoers.d`, where `agent`'s rule keeps `PATH` and the proxy variables. It deliberately has no `Defaults secure_path`, which overrides `PATH` regardless of `env_keep` and can't be unset from a drop-in. That gives up no real protection: `secure_path` stops a user's `PATH` from shadowing root's commands, but `agent` already has unrestricted root. Both files are `0440`, which sudo-rs's `visudo -c` requires. `visudo -c` runs at build time, so a syntax error fails the build instead of locking out `sudo`.

## Docker

The image ships the full Docker Engine, but **no daemon starts automatically**: there's no `ENTRYPOINT`, and nothing in `BASH_ENV` starts one. The CLI works against any daemon through a mounted socket or `DOCKER_HOST`. A context that wants DinD runs `start-dockerd`, which does nothing if a daemon is already reachable.

- DinD needs a privileged container and **exclusive** volumes for daemon data. Never share a volume between two active daemons.
- DinD tests must use a container with no host socket mount and verify that the daemon answering belongs to that container. Otherwise `start-dockerd` correctly returns without starting anything, and the test exercises the host daemon instead.

## Environment

Anything that must hold in every context goes in `ENV`. Anything that needs shell logic goes in `/etc/devcontainer/env.sh`, which `BASH_ENV` loads into every non-interactive bash, which is how `sbx` launches agents. It has to stay idempotent and quiet. Nothing may depend on `.bashrc` or `/etc/profile`, or on `PATH` additions for command lookup.

- The `ENV PATH` adds `/go/bin` only as a convenience for `go install`ed tools.
- `GOTOOLCHAIN=local` stops Go from silently downloading a different toolchain.
- The locale `ENV` comes after the step that runs `locale-gen`. Set earlier, the step would warn throughout that the locale doesn't exist.

### Login shell

`agent`'s and root's login shell is bash, and the image's `CMD` is `/bin/bash`. The kits' agent CLIs run their commands in bash too: Claude Code's Bash tool accepts only bash or zsh, and the Claude kit sets `CLAUDE_CODE_SHELL=/bin/bash` rather than leaving it to detection.

No credentials, tokens, or user config are ever baked into the image. Auth always comes from the consuming context at runtime.

## Docker Sandboxes contract

[Use your own Linux image](https://docs.docker.com/ai/sandboxes/customize/author/base-images/#use-your-own-linux-image) requires:

- [x] `agent` user, UID 1000, home `/home/agent`, in `/etc/passwd`, `USER agent` (set in each kit's Dockerfile, as in Docker's own workload example)
- [x] `curl`, `git`, CA certificates
- [x] Executable `/bin/sh` and `/bin/bash`
- [x] `ENTRYPOINT` or `CMD` set (the image uses `CMD ["/bin/bash"]`, and each kit sets its agent as `ENTRYPOINT`)
- [x] Absolute `WORKDIR`, used when no workspace is mounted
- [x] Persistent environment through `BASH_ENV`, not profiles
- [x] Agent tools installed as `agent`, not root

The `com.docker.sandbox/sbx@1` capability is declared in each kit descriptor, not on the image.

## Image metadata

The image carries OCI labels and a `devcontainer.metadata` label with the default `remoteUser: agent`, so a consumer's `devcontainer.json` can stay minimal. The Dockerfile sets the fixed ones (title, description, licenses, vendor). `docker-bake.hcl` adds the ones a build knows, when it's given them: source, revision, a documentation permalink to `docs/usage.md` at the building commit, and the base image's name and digest, which `publish.yml` reads from the `debian` stage's `FROM` pin. The published image index carries the same values as annotations. `org.opencontainers.image.licenses` is `CC0-1.0`, for the project's own contribution only ([legal.md](legal.md#packaging-and-metadata)).

A kit inherits every label of the image it pins, so each kit's dockerfile replaces the ones that describe the image. Title and description match the descriptor's `displayName` and `description`, which the kit frontend writes as the kit's manifest annotations along with `licenses` and `version`. The version is the mixin's tag, and the base name and digest come from the `IMAGE` pin, so every build gets them, including `sbx` building from a git ref. Revision and documentation are left empty, because only `publish-kits.yml` knows the kit's commit. It sets them with `--label`, the documentation permalink pointing at `docs/usage.md#agent-sandboxes-sbx`. Source, vendor, `devcontainer.metadata`, and DHI's `com.docker.dhi.*` labels stay as inherited. So does `licenses`, `CC0-1.0` for the project's own contribution as on the image, matching the descriptors' `licenses`: the agents' terms are recorded in `/legal/manifest.tsv`.
