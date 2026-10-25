# Tool inventory

Each tool gets one of three install methods, in order of preference:

1. **COPY**: copied from a pinned upstream image. Dependabot (`docker`) updates it.
2. **Script**: apt, or the latest upstream release verified against its published checksums. Not pinned; scheduled builds refresh them. Dependabot can't track these; see [maintenance.md](maintenance.md#updates-dependabot-cant-handle).
3. **Installer**: the vendor's official standalone installer, run as `agent`. Unpinned, and the tool self-updates at runtime. Used only for the agent CLIs.

| Tool | Method | Source | Location in image | Update path |
| --- | --- | --- | --- | --- |
| Ubuntu 26.04 LTS | base | `ubuntu:26.04` | n/a | Dependabot `docker` (digest) |
| Go | COPY | `golang:<ver>-trixie` | `/usr/local/go` | Dependabot `docker` |
| Node.js 26 + npm | COPY | `node:26-trixie-slim` | `/usr/local/bin/node`, `/usr/local/lib/node_modules/npm` | Dependabot `docker` |
| Python 3.15 + pip | COPY | `python:3.15-slim-trixie` | `/usr/local/bin/python3`, `/usr/local/lib/python3.15` | Dependabot `docker` |
| uv + uvx | COPY | `ghcr.io/astral-sh/uv` | `/usr/local/bin/uv`, `/usr/local/bin/uvx` | Dependabot `docker` |
| oras | COPY | `ghcr.io/oras-project/oras` | `/usr/local/bin/oras` | Dependabot `docker` |
| hadolint | COPY | `hadolint/hadolint` | `/usr/local/bin/hadolint` | Dependabot `docker` |
| shfmt | COPY | `mvdan/shfmt` | `/usr/local/bin/shfmt` | Dependabot `docker` |
| jq | COPY | `ghcr.io/jqlang/jq` | `/usr/local/bin/jq` | Dependabot `docker` |
| gomplate | COPY | `hairyhenderson/gomplate` | `/usr/local/bin/gomplate` | Dependabot `docker` |
| golangci-lint | COPY | `golangci/golangci-lint` | `/usr/local/bin/golangci-lint` | Dependabot `docker` |
| git-cliff | COPY | `orhunp/git-cliff` | `/usr/local/bin/git-cliff` | Dependabot `docker` |
| betterleaks | COPY | `ghcr.io/betterleaks/betterleaks` (dual-arch) | `/usr/local/bin/betterleaks` | Dependabot `docker` |
| pnpm | COPY | `ghcr.io/pnpm/pnpm` | `/opt/pnpm` (`pnpm`, `pn`, `pnpx`, `pnx`) | Dependabot `docker` |
| GitHub CLI | Script | Latest GitHub release tarball, verified against the release's `checksums.txt` | `/usr/local/bin/gh` | Weekly refresh; cache reusable otherwise |
| git | Script (apt) | `ppa:git-core/ppa` | system | Weekly refresh; cache reusable otherwise |
| Docker Engine (`docker-ce`, `docker-ce-cli`, `docker-buildx-plugin`, `docker-compose-plugin`, `containerd.io`) | Script (apt) | Docker's apt repository (`download.docker.com`) | `/usr/bin/docker`, `/usr/bin/dockerd`, CLI plugins | Weekly refresh; cache reusable otherwise |
| sudo-rs | Script (apt) | Ubuntu archive (`sudo-rs`) | `/usr/bin/sudo` | Weekly refresh; cache reusable otherwise |
| Claude Code | Installer | `https://claude.ai/install.sh` | `/home/agent/.local/bin/claude` | Weekly installer refresh; can self-update |
| Codex | Installer | `https://chatgpt.com/codex/install.sh` | `/home/agent/.local/bin/codex` | Weekly installer refresh; can self-update |

License and notice files for every component not installed with apt ship in `/legal/attribution`. apt packages keep theirs in `/usr/share/doc` (see [legal.md](legal.md)).

All listed tools remain preinstalled. The generated legal inventory also covers base-image and apt packages, their exact source provenance, and required transitive notices. Required source archives are published separately alongside the image.

Every primary command also resolves from `/usr/local/bin`, by copy or by symlink. See [architecture.md](architecture.md#default-path).

The "Location in image" column is where each binary ends up. The path *inside each source image* must be confirmed during implementation. Run `docker run --rm --entrypoint sh <image> -c 'command -v <tool>'`, or inspect the layers if the image has no shell.

## Notes per tool

- **Go.** Copy the whole `/usr/local/go` tree, not just the binary, because the toolchain needs `GOROOT`. Pin the tag to a minor line so Dependabot proposes patch bumps, and open minor bumps as their own PRs.
- **Python.** Use the latest stable CPython line, currently 3.15. The tag is pinned to the minor line (`3.15-slim-trixie`), so Dependabot proposes patch releases. Moving to the next minor (3.16) is a deliberate tag change, made once it's a final release, never a pre-release. Copy the whole `/usr/local` contribution of the image (interpreter, `libpython`, stdlib, headers, pip), then run `ldconfig`. Headers are kept so that packages with C extensions can build. The system `site-packages` is root-owned. Run as `agent`, `pip install` falls back to a user install in `~/.local`, whose `bin` isn't on the default `PATH`, so projects should use a virtual environment (`python3 -m venv`). Runtime library requirements are covered in [architecture.md](architecture.md#binary-compatibility).
- **uv.** The image is distroless and holds just the static `/uv` and `/uvx` binaries, which are copied into `/usr/local/bin`. No uv configuration is baked in. By default uv uses an installed interpreter that satisfies the project's `requires-python`, so the image's Python 3.15 is picked up. uv downloads a managed Python only when a project asks for a version the image doesn't have. Its cache (`~/.cache/uv`) and managed Pythons (`~/.local/share/uv`) are per-user. Tools from `uv tool install` land in `~/.local/bin`, which isn't on the default `PATH`; that's the same caveat as user `pip` installs.
- **oras.** An OCI registry client. The image's copyleft source is published as source images, linked from each image by a source index referrer, so shipping `oras` means anyone holding the image can find that source from inside it (see [legal.md](legal.md#finding-the-source)). It's also generally useful for pushing and pulling OCI artifacts.
- **Node.** Pinned to the 26 line. Moving to a new major is a deliberate tag change, not something Dependabot auto-merges. Corepack isn't used, since current Node releases no longer ship it. pnpm comes from its own image instead. Node links against `libatomic.so.1`, which the Ubuntu base doesn't ship, so `libatomic1` is installed with apt.
- **pnpm.** Copied from pnpm's official image (`ghcr.io/pnpm/pnpm`, the glibc `debian:stable-slim` variant, never `-alpine`). The image holds the standalone binary in `/opt/pnpm` with its bundled `node-gyp` in `/opt/pnpm/dist`, so the whole directory is copied. pnpm picks its command from `argv[0]`: `pn` is `pnpm`, and `pnpx`/`pnx` run `pnpm dlx`. Those aliases must be **hard links** in `/opt/pnpm`, because through a symlink the binary sees itself as `pnpm`. A builder stage creates the hard links and `COPY` preserves them; `/usr/local/bin` then gets symlinks to the four names. The published image doesn't contain the aliases yet, although pnpm's current install script creates them. Its global configuration (bin dir, shared store, fetch retries, CI install behavior) is described in [architecture.md](architecture.md#pnpm-configuration).
- **Claude Code and Codex.** The goal is availability, not version control. The standalone installers run as `agent` in the final stage, so the binaries land in `agent`'s home with the ownership they need to self-update. Weekly builds invalidate the installer cache to fetch current versions; other builds may retain the cached version. The smoke test checks that they're present and runnable. These are the only `curl | sh` installs allowed in the repository. Details are in [Agent installers](#agent-installers).
- **gh.** There's no official image. `scripts/install-gh.sh` runs in the `gh` builder stage. It resolves the latest release from the `releases/latest` redirect, not the rate-limited API, downloads the tarball for `TARGETARCH` and that release's `gh_<version>_checksums.txt`, and checks the tarball with `sha256sum -c`. The version isn't pinned, so no hashes are maintained by hand. The checksums come from the same release as the tarball, so they catch corrupt or truncated downloads, not a compromised release. The stage consumes the refresh build argument, so scheduled builds pick up new releases; other builds may reuse the cached binary. The script records the installed version in a `VERSION` file for the legal inventory.
- **sudo-rs.** It comes from the Ubuntu archive because it's a setuid system binary tied to PAM and the distro's config, so copying it in from an image isn't appropriate. `sudo` must resolve to sudo-rs (`sudo --version` reports `sudo-rs`), and the original `sudo` package must not be installed alongside it.
- **Docker Engine.** Installed from Docker's official apt repository, not Ubuntu's `docker.io` package. The repo's signing key is added to `/etc/apt/keyrings/docker.asc`, and its fingerprint is checked against the published value before use. The repository is keyed to the Ubuntu codename (from `/etc/os-release`), so the first build has to confirm that Docker publishes packages for 26.04. Copying static binaries out of `docker:dind` was ruled out: that image is Alpine-based, and the apt packages bring the systemd-free plumbing (`containerd`, `runc`, iptables dependencies) that DinD needs. See [architecture.md](architecture.md#docker) for how the daemon is run.
- **git.** Ubuntu's archive version lags behind upstream, and copying git out of another distro's image drags along its shared libraries and helpers. The git-core PPA is the least-bad option. Its signing key is `F911AB184317630C59970973E363C90F8F1B6217` (RSA-4096, Launchpad's `signing_key_fingerprint`). The PPA's `InRelease` is also signed by an older RSA-1024 key, which apt on 26.04 rejects, so trust only the RSA-4096 key. The trade-off: the version isn't pinned, so it floats to the PPA's latest when the apt installation layer is refreshed. Weekly builds force that refresh. It also satisfies the sandbox requirement for `git`.

## Agent installers

Behavior below comes from reading the installer scripts as fetched on 2026-10-25. It hasn't been run in a container yet; the first image build confirms it.

### Claude Code: `https://claude.ai/install.sh`

Redirects to `https://downloads.claude.ai/claude-code-releases/bootstrap.sh` (bash).

- **Requires** `bash`, plus `curl` or `wget`. It uses `jq` and `zstd` if present: `jq` to parse the manifest, `zstd` for a smaller compressed download. Copying `jq` in before this step helps; `zstd` is optional.
- **Fetches** the latest version string, then `manifest.json`, then the platform binary (`linux-x64` / `linux-arm64`, glibc variant on Ubuntu). It verifies the binary's SHA-256 against the manifest, and both arches are covered.
- **Installs** by running the downloaded binary's `claude install`, which sets up `~/.local/bin/claude` and the versioned install under `~/.local/share/claude/`. The temporary download in `~/.claude/downloads` is removed afterwards.
- **Refuses** to run under `sudo` from a non-root user, unless `CLAUDE_INSTALL_ALLOW_SUDO=1` is set. Running as `USER agent` avoids this.
- **Memory**: needs about 512 MB free during install. A low-memory build would be OOM-killed with exit code 137.
- **Optional argument** `stable | latest | X.Y.Z`. We pass nothing, which gives the default channel.

### Codex: `https://chatgpt.com/codex/install.sh`

Redirects to `https://releases.openai.com/codex/install.sh` (POSIX `sh`). The same script is also published as a GitHub release asset on `openai/codex`.

- **Requires** `mktemp`, `tar`, `curl` or `wget`, and one of `sha256sum`, `shasum`, or `openssl`. All of these are in the base image.
- **Fetches** the release from `releases.openai.com`, falling back to GitHub Releases. Setting `CODEX_INSTALLER_USE_RELEASES_OPENAI_COM=0` uses GitHub only. It verifies SHA-256 against the release's `codex-package_SHA256SUMS`.
- **Bundles** `ripgrep` (`codex-path/rg`), bubblewrap (`codex-resources/bwrap`, which reports no version; Codex vendors its source), and native voice libraries (GStreamer, GLib, and their dependencies) with their own `NOTICE.md`, `licenses/`, and `sources.json`. All are inventoried in `/legal` (see [legal.md](legal.md#component-licenses)).
- **Linux builds are musl** (`x86_64-unknown-linux-musl` / `aarch64-unknown-linux-musl`), so they're statically linked and don't depend on glibc. A bundled `bwrap` ships in `codex-resources/`.
- **Installs** to `$CODEX_HOME/packages/standalone/releases/<version>-<target>`, with a `current` symlink pointing at the active release and `~/.local/bin/codex` → `current/bin/codex`. Override with `CODEX_INSTALL_DIR` (bin dir) and `CODEX_HOME`.
- **Prompts** ("Start Codex now?", and whether to uninstall a conflicting npm/brew install) unless `CODEX_NON_INTERACTIVE=1`. The build sets this.
- **Runs** `codex` once, which leaves temp dirs in `~/.codex/tmp/arg0-linux`. In a lower image layer Codex can't rename them away (overlayfs returns `EXDEV`), so it would warn on every start. The install step deletes `~/.codex/tmp` in the same layer.
- **Edits** a shell profile chosen from `$SHELL` to add `~/.local/bin` to `PATH`. This is harmless, and nothing relies on it.
- **Optional** `--release VERSION` / `CODEX_RELEASE`. We pass nothing, which gives latest.

**Important:** Codex keeps its binaries inside `CODEX_HOME` (default `~/.codex`), the same directory that holds its config and auth. **Mounting a host `~/.codex` over `/home/agent/.codex` hides the installed binary.** From a macOS host, it would also expose Darwin binaries. Consumers should either mount only the files they need (`auth.json`, `config.toml`) or log in inside the container. Claude Code doesn't have this problem: its binaries live in `~/.local/share/claude`, separate from `~/.claude`.
