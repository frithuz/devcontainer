# Architecture

## Repository layout

- `Dockerfile`, `docker-bake.hcl`: the image and its Bake targets, shared by CI and local builds.
- `rootfs/`: files copied into the image as-is (the `BASH_ENV` script and `start-dockerd`).
- `legal/`, `scripts/`: the committed `/legal` documents, the scripts that collect notices and plan source images, and their schema-validated YAML data.
- `scripts/build/`: the nu scripts the Dockerfiles' `RUN` steps mount and run, through `run.nu`, which prints each one and its sha256 into the build log first.
- `source.Dockerfile`: builds [source images](legal.md#source-images).
- `test/`: `smoke.sh`, the smoke tests the `preflight` stage runs through `preflight.nu`, and `runtime.sh`, the DinD checks, run by `ci.yml` against a built image.
- `.github/workflows/`: `lint.yml` (the workflow and repository linters), `ci.yml` (DinD checks and source planning on PRs), `publish.yml`, partly implemented ([maintenance.md](maintenance.md#publishing-publishyml)), `kits.yml`, which keeps the sandbox kits pinned to the latest image ([maintenance.md](maintenance.md#sandbox-kits)), and `publish-kits.yml`, which publishes them ([maintenance.md](maintenance.md#publishing-the-kits)).
- `sandboxes/`: Docker Sandboxes kits, one `devcontainer-<agent>` directory per agent ([usage.md](usage.md#agent-sandboxes-sbx)).

## Dockerfile structure

The Dockerfile has four kinds of stages. The comments in the file cover the details of each step.

**Source stages** declare each upstream image once, as a plain `image:tag@sha256:digest`. Dependabot's `docker` ecosystem can parse only that form, so build args never appear in a reference. Digests must be **multi-arch index digests**. A per-platform digest would make an arm64 build pull an amd64 binary.

The base is one of them: the `debian` stage pins [Docker Hardened Images](https://docs.docker.com/dhi/)' Debian 13 base, the `-dev` variant (it runs as root and ships apt), pulled from `dhi.io`, which needs a Docker login. The final stage and the stages that compile for it start from it, so they link against the same libraries.

**Builder stages** hold anything fetched or built by script that doesn't belong in a user's home: `gh`, `jv`, `task`, `dnslookup`, git, nushell, and the apt signing key. That keeps `gnupg`, compilers, and other fetch and build tooling out of the final image. Most start from `builder`, the `go` stage with nu added, because every `RUN` script is written in nu (AGENTS.md). The `git` stage starts from `debian` instead ([git](#git)), and the `nushell` stage, which compiles the nu the others use, from `rust` ([nushell](#nushell)). The `config` stage validates `scripts/*.yaml` against their schemas and converts them to JSON. The scripts read only that output, so a malformed data file fails the build before anything uses it.

**The `files` stage** lays out, under `/out`, every file the image copies in: the toolchains and standalone tools, git's `/usr/local` tree, the pnpm hard links, the `/usr/local/bin` symlinks, the apt signing key, `rootfs/`, and the notices `/legal` starts from. Hard links survive because they're copied within one `COPY`.

**The final stage (`image`)** has as few layers as possible, three:

1. `COPY --link --from=files /out/ /`, first, so the setup step can use the toolchains and nu. It doesn't consume `REFRESH`.
2. One `RUN` for the system: apt (base packages and Docker Engine), the locale, the shared directories, and the `agent` user.
3. The `/legal` step. It reads `REVISION`, which changes on every commit, so it stays separate. Merged into step 2, every build would reinstall everything.

The `ENV` instructions sit between steps 2 and 3. They add no layers, and after step 2 the locale they select exists.

The trade-off is cache reuse. Bumping any copied tool, or changing any file `files` copies, invalidates step 2, so apt and the agent installs run again. The stage declares `REFRESH` before step 2, so the weekly build, which changes it, re-runs it too. That's what refreshes the apt packages and the agent installs. Otherwise an unchanged step stays cached indefinitely, and rebuilding the pinned base digest doesn't refresh it. Keep `REFRESH` out of the copied tools' source stages. `COPY --link` can't follow a destination symlink from an earlier layer, so nothing under `/out` may land on one in the base image (`/bin`, `/lib`, and `/sbin` are symlinks in the base).

apt is used only for what can't be copied: base OS packages and Docker Engine. Packages come from Docker's hardened rebuilds (`dhi.io`, `+dhi` versions) where Docker has one, and otherwise from Debian's archive. Every apt source is HTTPS: the base ships plain-HTTP Debian and DHI sources, which `apt-bootstrap.nu` rewrites, and its own CA certificates. The apt lists live in a cache mount, so they never reach a layer.

**The `preflight` stage** builds on `image` for PR CI and local checks, and is never published. It runs the smoke tests and exports their report, and each platform's `/legal/manifest.tsv`, which source planning starts from. Publishing builds `image` once and tests that exact digest. It never relies on preflight or cache reuse for the image's identity ([maintenance.md](maintenance.md#workflow)). A refresh builds preflight first, only to decide whether the inventory changed ([maintenance.md](maintenance.md#material-changes)).

## Binary compatibility

Copied binaries have to run on the base's glibc (Debian 13's):

- Prefer statically linked binaries. Most of the Go tools and uv are.
- Copy dynamically linked tools (Node, Python, git-cliff, pnpm) only from glibc (Debian-based) images whose glibc is no newer than the base's. Never copy them from Alpine/musl images.
- **Python** needs the most care. The official image links CPython against Debian's shared libraries, so the final stage installs the same packages. A missing library doesn't break `python3 --version`. It shows up only when the matching stdlib module is imported, which is why the smoke tests import each of them.

## git

git is compiled from source in the `git` stage (`scripts/build/git.nu`), so the image runs a current release built for how it's used, not the distribution's. The stage starts from `debian`, the base the image runs on, so git links against exactly the libraries the image installs. It installs under `/usr/local` with its built-in commands as symlinks rather than hard links, so the `files` stage copies it as one tree.

**Verified before use.** The release tarball's signature must verify against the maintainer's key, pinned by fingerprint (`SIGNER`). The keyserver's answer must be that key alone, and gpg's `VALIDSIG` must name it as the signing key's primary: a good signature by any other key fails. zlib-ng publishes no signatures (lightweight tags, unsigned commits), so its archive is pinned by commit and SHA-256 instead, and its header must report the pinned version.

**Compiled in.** [zlib-ng](https://github.com/zlib-ng/zlib-ng), statically, in place of zlib: faster compression for clone, fetch, gc, and reading objects. It picks its CPU-specific code at run time, so one build suits every host. git's Rust code is compiled with the toolchain copied from the pinned `rust` stage; it has no crate dependencies, so cargo runs offline.

**Build options:**

- Debian's hardening flags and link-time optimization, from `dpkg-buildflags`. The base drops dpkg's default vendor, and without one `dpkg-buildflags` prints nothing, so the script sets `DEB_VENDOR=Debian`, fails if the flags lack the stack protector or LTO, and checks the linked binary for full RELRO and a stack protector.
- `sysconfdir=/etc`, so the system config stays `/etc/gitconfig`, where `git config --system` (the kits' commit signing) and other tools expect it.
- OpenSSL's accelerated SHA-1 only where git doesn't need collision detection (checksums of files it writes itself); object IDs keep the collision-detecting SHA-1. OpenSSL also provides SHA-256.
- PCRE2 for `git grep -P`; HTTPS through the image's libcurl.
- No Perl, Python, Tcl/Tk, translations, or expat: no `send-email`, `svn`, `p4`, `gitk`, `git-gui`, or WebDAV `http-push`.

**Tested before install.** git's test suite runs through `prove`, then `git subtree`'s, and zlib-ng's runs before git is built. A failure fails the stage. The stage is cached, so the tests only run again when its inputs change: the versions, `git.nu`, or the base digest.

**Client only.** The daemon, `http-backend`, `git-shell`, `imap-send`, `instaweb`, and the scripts that would only report a missing Perl or Python are removed after install. A release that stops shipping one fails the build, so the list stays accurate. `git subtree` is installed from `contrib/`. There are no man pages or shell completion: use `git <command> -h`.

To bump: `VERSION` for git; `ZLIB_NG_VERSION`, `ZLIB_NG_COMMIT`, and `ZLIB_NG_SHA256` together for zlib-ng; `SIGNER` only if git's maintainer changes signing keys. The smoke tests check git's version against `VERSION` and zlib-ng's against `ZLIB_NG_VERSION`. Changing `git.nu` changes git's [source image](legal.md#compiled-components), which carries the script.

## nushell

nu is compiled in the `nushell` stage (`scripts/build-nushell.sh`) from its crates.io release, rather than copied from nushell's image, so the image controls its size and features. Every other stage runs its scripts with this nu, so the build script is bash, the one exception to the nu rule. The stage starts from `rust`, which is Debian 13 like the base, so nu links against the same glibc. Its only other libraries are libgcc_s and libm.

**Verified before use.** The `.crate` archive is pinned by SHA-256 (`SHA256`), which `ADD --checksum` checks before the build sees it. crates.io archives are immutable. cargo builds with `--locked`, so every dependency must match its checksum in the release's `Cargo.lock`. The script fails if nu reports a version other than `VERSION` or lacks any of `FEATURES`.

**Sized for shipping.** Fat LTO with one codegen unit and no symbol table, on top of nushell's own release profile (`opt-level = "s"`). That makes nu about 35 MB, down from 79 MB with nushell's profile alone. The build runs outside the source tree, because rustup reads the `rust-toolchain.toml` in the working directory, and nushell's pins an older toolchain than the `rust` stage's.

**Features:** nushell's defaults without `trash-support`, since a container has no desktop trash: `mcp` (`nu --mcp`, which the agents' MCP config uses), `network` (`http`, which the build scripts use), `rustls-tls` (TLS without OpenSSL, trusting the system CA store), `lsp`, `dap`, `plugin`, and `sqlite`. `system-clipboard` stays off, since there's no display.

`source.Dockerfile` gets the same nu through a bake named context (`nushell = "target:nushell"`), built for the build platform. In CI, the jobs that plan or build source images first build that target from publish's cache of the image build (`image-linux-amd64`), so nu isn't compiled again. To bump: `VERSION` and `SHA256` together, the `.crate`'s checksum as crates.io's API reports it (`https://crates.io/api/v1/crates/nu/<version>`). The smoke tests check nu's version against `VERSION`.

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

`agent`'s login shell is nu (`/usr/local/bin/nu`, listed in `/etc/shells`), so an interactive login, such as an editor's terminal, opens in nu. root keeps bash, and the image's `CMD` stays `/bin/bash`. The `ENV` and `BASH_ENV` rules above don't change: nothing may depend on nu's config either.

The kits' agent CLIs still run their commands in bash. Claude Code's Bash tool accepts only bash or zsh, so the Claude kit sets `CLAUDE_CODE_SHELL=/bin/bash` rather than leaving it to detection. Codex reads the login shell from `/etc/passwd`, doesn't recognize nu, and falls back to bash on Linux. Neither runs nu for its tool calls, so don't point either one at it.

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
