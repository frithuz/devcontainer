# Tool inventory

Each tool gets one of four install methods, in order of preference:

1. **COPY**: copied from a pinned upstream image. Dependabot (`docker`) updates it.
2. **npm**: installed from `tools/package-lock.json` in a builder stage. Dependabot (`npm`) updates it.
3. **Script**: a pinned version plus checksum, or apt. Dependabot can't track these; see [maintenance.md](maintenance.md#updates-dependabot-cant-handle).
4. **Installer**: the vendor's official standalone installer, run as `agent`. Unpinned, and the tool self-updates at runtime. Used only for the agent CLIs.

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
| pnpm | npm | `pnpm` | `/opt/tools` | Dependabot `npm` |
| GitHub CLI | Script | GitHub release tarball + SHA-256 | `/usr/local/bin/gh` | Scheduled check (see maintenance) |
| git | Script (apt) | `ppa:git-core/ppa` | system | Picked up on each rebuild |
| Docker Engine (`docker-ce`, `docker-ce-cli`, `docker-buildx-plugin`, `docker-compose-plugin`, `containerd.io`) | Script (apt) | Docker's apt repository (`download.docker.com`) | `/usr/bin/docker`, `/usr/bin/dockerd`, CLI plugins | Picked up on each rebuild |
| sudo-rs | Script (apt) | Ubuntu archive (`sudo-rs`) | `/usr/bin/sudo` | Picked up on each rebuild |
| Claude Code | Installer | `https://claude.ai/install.sh` | `/home/agent/.local/bin/claude` | Self-updates; latest at build |
| Codex | Installer | `https://chatgpt.com/codex/install.sh` | `/home/agent/.local/bin/codex` | Self-updates; latest at build |

License and notice files for every component not installed with apt ship in `/legal/attribution`. apt packages keep theirs in `/usr/share/doc` (see [legal.md](legal.md)).

Every primary command also resolves from `/usr/local/bin`, by copy or by symlink. See [architecture.md](architecture.md#default-path).

The "Location in image" column is where each binary ends up. The path *inside each source image* must be confirmed during implementation. Run `docker run --rm --entrypoint sh <image> -c 'command -v <tool>'`, or inspect the layers if the image has no shell.

## Notes per tool

- **Go.** Copy the whole `/usr/local/go` tree, not just the binary, because the toolchain needs `GOROOT`. Pin the tag to a minor line so Dependabot proposes patch bumps, and open minor bumps as their own PRs.
- **Python.** Use the latest stable CPython line, currently 3.15. The tag is pinned to the minor line (`3.15-slim-trixie`), so Dependabot proposes patch releases. Moving to the next minor (3.16) is a deliberate tag change, made once it's a final release, never a pre-release. Copy the whole `/usr/local` contribution of the image (interpreter, `libpython`, stdlib, headers, pip), then run `ldconfig`. Headers are kept so that packages with C extensions can build. The system `site-packages` is root-owned. Run as `agent`, `pip install` falls back to a user install in `~/.local`, whose `bin` isn't on the default `PATH`, so projects should use a virtual environment (`python3 -m venv`). Runtime library requirements are covered in [architecture.md](architecture.md#binary-compatibility).
- **uv.** The image is distroless and holds just the static `/uv` and `/uvx` binaries, which are copied into `/usr/local/bin`. No uv configuration is baked in. By default uv uses an installed interpreter that satisfies the project's `requires-python`, so the image's Python 3.15 is picked up. uv downloads a managed Python only when a project asks for a version the image doesn't have. Its cache (`~/.cache/uv`) and managed Pythons (`~/.local/share/uv`) are per-user. Tools from `uv tool install` land in `~/.local/bin`, which isn't on the default `PATH`; that's the same caveat as user `pip` installs.
- **oras.** An OCI registry client. The image's own copyleft source bundles are published as OCI referrer artifacts, so shipping `oras` means anyone holding the image can fetch that source from inside it (see [legal.md](legal.md#finding-the-source)). It's also generally useful for pushing and pulling OCI artifacts.
- **Node.** Pinned to the 26 line. Moving to a new major is a deliberate tag change, not something Dependabot auto-merges. Corepack isn't used, since current Node releases no longer ship it. pnpm comes from the npm lockfile instead.
- **pnpm.** Installing from a lockfile (`npm ci`) instead of `npm i -g pnpm@ver` gives integrity-hash verification and makes the package visible to Dependabot. Its global configuration (bin dir, shared store, fetch retries, CI install behavior) is described in [architecture.md](architecture.md#pnpm-configuration).
- **Claude Code and Codex.** The goal is availability, not version control. The standalone installers run as `agent` in the final stage, so the binaries land in `agent`'s home with the ownership they need to self-update. Build-time version is whatever was latest when the image was built. The smoke test only checks that they're present and runnable. These are the only `curl | sh` installs allowed in the repository. Details are in [Agent installers](#agent-installers).
- **gh.** There's no official image. The install script takes a version and per-arch SHA-256 sums from the `ARG`s at the top of the Dockerfile and verifies them against the downloaded tarball.
- **sudo-rs.** It comes from the Ubuntu archive because it's a setuid system binary tied to PAM and the distro's config, so copying it in from an image isn't appropriate. `sudo` must resolve to sudo-rs (`sudo --version` reports `sudo-rs`), and the original `sudo` package must not be installed alongside it.
- **Docker Engine.** Installed from Docker's official apt repository, not Ubuntu's `docker.io` package. The repo's signing key is added to `/etc/apt/keyrings/docker.asc`, and its fingerprint is checked against the published value before use. The repository is keyed to the Ubuntu codename (from `/etc/os-release`), so the first build has to confirm that Docker publishes packages for 26.04. Copying static binaries out of `docker:dind` was ruled out: that image is Alpine-based, and the apt packages bring the systemd-free plumbing (`containerd`, `runc`, iptables dependencies) that DinD needs. See [architecture.md](architecture.md#docker) for how the daemon is run.
- **git.** Ubuntu's archive version lags behind upstream, and copying git out of another distro's image drags along its shared libraries and helpers. The git-core PPA is the least-bad option. The trade-off: the version isn't pinned, so it floats to the PPA's latest whenever the image is rebuilt. It also satisfies the sandbox requirement for `git`.

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
- **Linux builds are musl** (`x86_64-unknown-linux-musl` / `aarch64-unknown-linux-musl`), so they're statically linked and don't depend on glibc. A bundled `bwrap` ships in `codex-resources/`.
- **Installs** to `$CODEX_HOME/packages/standalone/releases/<version>-<target>`, with a `current` symlink pointing at the active release and `~/.local/bin/codex` → `current/bin/codex`. Override with `CODEX_INSTALL_DIR` (bin dir) and `CODEX_HOME`.
- **Prompts** ("Start Codex now?", and whether to uninstall a conflicting npm/brew install) unless `CODEX_NON_INTERACTIVE=1`. The build sets this.
- **Edits** a shell profile chosen from `$SHELL` to add `~/.local/bin` to `PATH`. This is harmless, and nothing relies on it.
- **Optional** `--release VERSION` / `CODEX_RELEASE`. We pass nothing, which gives latest.

**Important:** Codex keeps its binaries inside `CODEX_HOME` (default `~/.codex`), the same directory that holds its config and auth. **Mounting a host `~/.codex` over `/home/agent/.codex` hides the installed binary.** From a macOS host, it would also expose Darwin binaries. Consumers should either mount only the files they need (`auth.json`, `config.toml`) or log in inside the container. Claude Code doesn't have this problem: its binaries live in `~/.local/share/claude`, separate from `~/.claude`.
