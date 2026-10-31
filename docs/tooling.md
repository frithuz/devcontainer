# Tooling

The [`Dockerfile`](../Dockerfile) is the inventory: its source stages list every copied tool with its pinned version, and the final stage shows what's installed with apt or a script. This page covers how tools are chosen and the quirks behind specific ones.

## Install methods

Each tool gets one of three methods, in order of preference:

1. **COPY** from a pinned upstream image. Dependabot updates the pin, and the binary is exactly what upstream shipped.
2. **Built or downloaded** in its own stage at a pinned version, bumped by hand: `go install` for Go tools without an image, and git from its signed release tarball. A tool whose dependencies include copyleft code (Task's MPL-2.0 Go modules, Sampo's MPL-2.0 Rust crate) is downloaded instead, as upstream's release archive pinned by SHA-256 per architecture, so upstream's binary carries the source obligation ([legal.md](legal.md#copyleft-components)).
3. **Script**: apt, or a release download verified against its published checksums. These aren't pinned. The weekly build refreshes them, and Dependabot can't track them ([maintenance.md](maintenance.md#updates-dependabot-cant-handle)).

A tool falls back to a script only when there's no usable image: no upstream image (`gh`), or a binary that shouldn't be copied from an image (setuid `sudo-rs`, Docker Engine with its daemon plumbing).

## Quirks per tool

- **Go and Python** pin their tag to a minor line, so Dependabot proposes patch releases only. Moving to a new minor is a deliberate tag change. For Python, that happens once the new minor is final, never on a pre-release. Go is copied as the whole `/usr/local/go` tree because the toolchain needs its `GOROOT`.
- **Python** keeps its headers, so packages with C extensions can build. The system `site-packages` is root-owned, so `pip install` as `agent` falls back to `~/.local`, which isn't on the default `PATH`. Projects should use a virtual environment. Its shared-library requirements are in [architecture.md](architecture.md#binary-compatibility).
- **uv** has no configuration baked in. It picks up the image's Python when that satisfies `requires-python`, and downloads a managed Python only when a project needs another version. `uv tool install` lands in `~/.local/bin`, which has the same `PATH` caveat as `pip`.
- **Node** doesn't use Corepack (current releases no longer ship it). pnpm comes from its own image. Node links against `libatomic.so.1`, which the base lacks, so `libatomic1` comes from apt.
- **pnpm** picks its command from `argv[0]`, so the `pn`, `pnpx`, and `pnx` aliases have to be **hard links** next to the binary. Through a symlink, the binary sees itself as `pnpm`. The published image ships them as hard links of one binary, and the image's single `COPY` keeps them. Copy from the glibc variant, never `-alpine`. Its global configuration is in [architecture.md](architecture.md#pnpm-configuration).
- **gh** has no official image. The install script resolves the latest release through the `releases/latest` redirect instead of the rate-limited API. The checksums come from the same release as the tarball, so they catch a corrupt download, not a compromised release.
- **jv and Task** have no upstream images and are built with `go install` at pinned versions, so they're bumped by hand. Task supplies the `task` command for repository automation, including `task repo:init`.
- **dnslookup** is the DNS client, in place of dig (MPL-2.0). It's built the same way, with a linker flag (`LDFLAGS` in its stage) that sets its version string. Without it, `--version` prints `master` and the smoke tests' pin check fails.
- **gh-stack** is the GitHub CLI extension for stacked pull requests (`gh stack`). Its releases publish no checksums, so it's built from its pinned module the same way, with the linker flag its release builds set. The setup step installs it as `agent`'s extension, laid out as `gh extension install github/gh-stack` would: `~/.local/share/gh/extensions/gh-stack/`, with a link to `/usr/local/bin/gh-stack` and a manifest pinned to the image's version, so `gh extension upgrade` leaves it alone. Other users, such as root in a GitHub Actions job, don't get the extension, but `gh-stack` runs on its own.
- **dbmate**, the database migration tool, is copied from its Alpine-based image. That's safe only because the binary is fully static (a cgo build with SQLite, linked statically against musl), so recheck `file` on it if upstream changes how it builds ([architecture.md](architecture.md#binary-compatibility)). Its MySQL driver is MPL-2.0, compiled in upstream ([legal.md](legal.md#copyleft-components)).
- **Sampo**, the changeset-based release tool, has no upstream image and its releases publish no checksums. It's downloaded like Task: upstream's `*-unknown-linux-gnu` release archive, pinned by SHA-256 per architecture, because its Rust dependencies include an MPL-2.0 crate (`option-ext`). The archive has no LICENSE, so the stage fetches it from the release tag, pinned by SHA-256 too. The binary links against glibc and needs 2.39 or newer as of 0.23.0 ([architecture.md](architecture.md#binary-compatibility)).
- **fd and bat** come from apt, where Debian renames them `fdfind` and `batcat`. The setup step links the upstream names into `/usr/local/bin`.
- **toybox** stands in for iproute2 (GPL-2): `netstat` and `ifconfig` are links to it in `/usr/local/bin`, and `lsof -i` covers the rest of what `ss` did. Nothing permissive replaces `ip route`, `tc`, or `bridge`; routes are readable in `/proc/net/route`. Its other commands aren't linked, so they don't shadow the system's.
- **socat** is how Docker Sandboxes forwards the host's SSH agent: sbx starts `socat UNIX-LISTEN:/run/ssh-agent.sock` in the sandbox, relaying to the gateway, and skips the relay without an error when socat is missing. Without it, `/run/ssh-agent.sock` never appears, so git over SSH and commit signing both fail.
- **sudo-rs** comes from apt: it's a setuid binary tied to PAM and the distro's configuration. Debian installs it under other names and without a sudoers file, which the setup step supplies ([architecture.md](architecture.md#users)). The original `sudo` package must never be installed alongside it.
- **Docker Engine** comes from Docker's apt repository, not Debian's `docker.io`. Copying binaries out of `docker:dind` isn't an option: that image is Alpine-based, and the apt packages bring the plumbing DinD needs (`containerd`, `runc`, iptables). The repository is keyed to the Debian codename, so a new Debian release depends on Docker publishing for it.
- **git** is compiled from its signed release tarball, with zlib-ng for faster compression ([architecture.md](architecture.md#git)). Debian's git lags upstream, and copying git out of another image drags its libraries and helpers along. It's a client build: no servers, no Perl or Python commands, no man pages or completion. `git subtree` is included.

## Agents

The image carries no agent CLIs: CI doesn't use them, and the [sandbox kits](usage.md#agent-sandboxes-sbx) add them. Each kit's dockerfile copies the agent out of Docker's mixin for it (`docker.io/docker/sbx-kit-claude-mixin`, `sbx-kit-codex-mixin`), pinned by version tag and digest, onto the image ([maintenance.md](maintenance.md#sandbox-kits)). The binaries are root-owned, so the agents stay at the pinned version.

**Claude Code** is one native binary, `/usr/local/bin/claude`. Its updater is off (`DISABLE_AUTOUPDATER=1`), and its Bash tool is pinned to bash (`CLAUDE_CODE_SHELL=/bin/bash`), since it accepts only bash or zsh.

**Codex** is its release package, under `/opt/codex`, with a link on `PATH`. It's a static musl build, so glibc doesn't matter. The kit changes the package two ways:

- **No voice libraries.** `codex-resources/voice` (GStreamer and GLib, LGPL) needs audio devices a sandbox doesn't have.
- **The image's `bwrap`.** Codex's app server, which its terminal UI starts, refuses a package without `codex-resources/bwrap`, though the kit runs Codex with its own sandbox off. The kit copies in the image's `bwrap`, from Debian's `bubblewrap` package, in place of the copy Codex vendors, so the kit adds no copyleft code of its own ([legal.md](legal.md#sandbox-kits)). It has to be a copy: Codex rejects a link that leaves its package. The app server also needs `ps`, which is why the image installs `procps`.

Codex's app server copies the package into `CODEX_HOME` (`~/.codex`) when it starts, so nothing mounts over that directory. The mixins ship no license notices, so each kit's `legal.sh` adds them and appends the agent's rows to the kit's `/legal/manifest.tsv`.

Outside a sandbox, install an agent with its vendor's installer.
