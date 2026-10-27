# Tooling

The [`Dockerfile`](../Dockerfile) is the inventory: its source stages list every copied tool with its pinned version, and the final stage shows what's installed with apt or a script. This page covers how tools are chosen and the quirks behind specific ones.

## Install methods

Each tool gets one of three methods, in order of preference:

1. **COPY** from a pinned upstream image. Dependabot updates the pin, and the binary is exactly what upstream shipped.
2. **Script**: apt, or a release download verified against its published checksums. These aren't pinned. The weekly build refreshes them, and Dependabot can't track them ([maintenance.md](maintenance.md#updates-dependabot-cant-handle)).
3. **Vendor installer**, run as `agent`. Used only for the agent CLIs, which self-update at runtime.

A tool falls back to a script only when there's no usable image: no upstream image (`gh`), or a binary that shouldn't be copied from an image (setuid `sudo-rs`, git with its libraries and helpers, Docker Engine with its daemon plumbing).

## Quirks per tool

- **Go and Python** pin their tag to a minor line, so Dependabot proposes patch releases only. Moving to a new minor is a deliberate tag change. For Python, that happens once the new minor is final, never on a pre-release. Go is copied as the whole `/usr/local/go` tree because the toolchain needs its `GOROOT`.
- **Python** keeps its headers, so packages with C extensions can build. The system `site-packages` is root-owned, so `pip install` as `agent` falls back to `~/.local`, which isn't on the default `PATH`. Projects should use a virtual environment. Its shared-library requirements are in [architecture.md](architecture.md#binary-compatibility).
- **uv** has no configuration baked in. It picks up the image's Python when that satisfies `requires-python`, and downloads a managed Python only when a project needs another version. `uv tool install` lands in `~/.local/bin`, which has the same `PATH` caveat as `pip`.
- **oras** ships so that anyone holding the image can find its copyleft source from inside it ([legal.md](legal.md#finding-the-source)).
- **Node** doesn't use Corepack (current releases no longer ship it). pnpm comes from its own image. Node links against `libatomic.so.1`, which the Ubuntu base lacks, so `libatomic1` comes from apt.
- **pnpm** picks its command from `argv[0]`, so the `pn`, `pnpx`, and `pnx` aliases have to be **hard links** next to the binary. Through a symlink, the binary sees itself as `pnpm`. The published image doesn't include the aliases yet, so the `files` stage creates them. Copy from the glibc variant, never `-alpine`. Its global configuration is in [architecture.md](architecture.md#pnpm-configuration).
- **gh** has no official image. The install script resolves the latest release through the `releases/latest` redirect instead of the rate-limited API. The checksums come from the same release as the tarball, so they catch a corrupt download, not a compromised release.
- **jv and Task** have no upstream images and are built with `go install` at pinned versions, so they're bumped by hand. Task supplies the `task` command for repository automation, including `task repo:init`.
- **dnslookup** is the DNS client, in place of dig (MPL-2.0). It's built the same way, with a linker flag (`LDFLAGS` in its stage) that sets its version string. Without it, `--version` prints `master` and the smoke tests' pin check fails.
- **gh-stack** is the GitHub CLI extension for stacked pull requests (`gh stack`). Its releases publish no checksums, so it's built from its pinned module the same way, with the linker flag its release builds set. The setup step installs it as `agent`'s extension, laid out as `gh extension install github/gh-stack` would: `~/.local/share/gh/extensions/gh-stack/`, with a link to `/usr/local/bin/gh-stack` and a manifest pinned to the image's version, so `gh extension upgrade` leaves it alone. Other users, such as root in a GitHub Actions job, don't get the extension, but `gh-stack` runs on its own.
- **nushell** is copied from the `-bookworm` (glibc) variant of its image, never `-alpine`. Only `nu` is copied: the `nu_plugin_*` binaries the image also ships aren't included. That build includes the `mcp` feature, so `nu --mcp` serves Nushell's MCP server over stdio, or HTTP with `--mcp-transport http`. The smoke tests fail if a new version drops it. It's `agent`'s login shell ([architecture.md](architecture.md#login-shell)).
- **fd and bat** come from apt, where Debian renames them `fdfind` and `batcat`. The setup step links the upstream names into `/usr/local/bin`.
- **toybox** stands in for iproute2 (GPL-2): `netstat` and `ifconfig` are links to it in `/usr/local/bin`, and `lsof -i` covers the rest of what `ss` did. Nothing permissive replaces `ip route`, `tc`, or `bridge`; routes are readable in `/proc/net/route`. Its other commands aren't linked, so they don't shadow the system's.
- **sudo-rs** comes from the Ubuntu archive: it's a setuid binary tied to PAM and the distro's configuration. The original `sudo` package must never be installed alongside it.
- **Docker Engine** comes from Docker's apt repository, not Ubuntu's `docker.io`. Copying binaries out of `docker:dind` isn't an option: that image is Alpine-based, and the apt packages bring the plumbing DinD needs (`containerd`, `runc`, iptables). The repository is keyed to the Ubuntu codename, so a new Ubuntu release depends on Docker publishing for it.
- **git** comes from the git-core PPA. Ubuntu's archive lags upstream, and copying git out of another image drags its libraries and helpers along. The PPA's `InRelease` is also signed with an old RSA-1024 key that apt on 26.04 rejects, so only the RSA-4096 key is trusted.

## Agent installers

Claude Code and Codex aim for availability, not version control. Their standalone installers run as `agent`, so the binaries land in `agent`'s home with the ownership they need to self-update. The weekly build refreshes them, and other builds may reuse a cached install. These are the only downloaded scripts piped to a shell (`http get ... | sh`) allowed in the repository.

**Claude Code** refuses to install as root under `sudo` from a non-root user, which is why the setup step switches to `agent` with `setpriv` instead. The install needs about 512 MB of free memory, and a low-memory build gets OOM-killed (exit 137).

**Codex** is a static musl build, so glibc doesn't matter. It bundles ripgrep, bubblewrap, and native voice libraries (GStreamer, GLib), each with license and source obligations of its own ([legal.md](legal.md#copyleft-components)). Other quirks:

- The installer prompts unless `CODEX_NON_INTERACTIVE=1` is set.
- The installer runs `codex` once, which leaves temp directories in `~/.codex/tmp`. In a lower image layer Codex can't rename them away (overlayfs returns `EXDEV`), so it warns on every start unless the install step deletes them.
- **Codex keeps its binaries in `CODEX_HOME` (`~/.codex`), next to its config and auth.** Mounting a host `~/.codex` hides the installed binary, and from a macOS host it also exposes Darwin binaries. Consumers mount individual files instead ([usage.md](usage.md#editor-devcontainers)). Claude Code doesn't have this problem: its binaries live in `~/.local/share/claude`, not `~/.claude`.

Both installers append a `PATH` line to a shell profile. Nothing relies on it.
