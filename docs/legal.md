# Legal notices and attribution

## Project license

This project's own code, configuration, and documentation are dedicated to the public domain under **Creative Commons Zero v1.0 Universal** (`CC0-1.0`, full text in [`LICENSE`](../LICENSE)). Third-party material, including everything installed or copied into the image, keeps its own licenses and terms.

### Impacts

- **Reuse:** anyone can copy, modify, and redistribute the project's work, commercially too, without attribution or publishing changes ([CC0 FAQ](https://wiki.creativecommons.org/wiki/CC0_FAQ#Does_CC0_require_others_who_use_my_work_to_give_me_attribution.3F)).
- **Permanence and limits:** the waiver is irrevocable for work already released, falls back to an unconditional license where a waiver isn't effective, and grants no patent or trademark license ([CC0 §§2–4](https://creativecommons.org/publicdomain/zero/1.0/legalcode.en)).
- **Software:** Creative Commons permits CC0 for software and calls it GPL-compatible ([FAQ](https://wiki.creativecommons.org/wiki/CC0_FAQ#May_I_apply_CC0_to_computer_software.3F_If_so.2C_is_there_a_recommended_implementation.3F)). The missing patent grant can still matter to downstream adopters.
- **Redistributed components:** CC0 for this project waives nothing on behalf of third parties. The image still owes upstream notices, GPL/LGPL/MPL source, and compliance with proprietary terms. Everything below exists for that reason.
- **Contributions:** accepted under CC0-1.0. Contributors must have the authority to dedicate them, and imported material keeps its upstream terms.

### Packaging and metadata

The image copies `LICENSE` to `/legal/LICENSE` and records the project's own installed files under `CC0-1.0`, separately from third-party components. That copy is this project's packaging convention, not a condition CC0 imposes on anyone.

The image label `org.opencontainers.image.licenses="CC0-1.0"` describes **only the project's own contribution**. The OCI spec is ambiguous about whether this field means the project or everything inside the image ([image-spec#1257](https://github.com/opencontainers/image-spec/issues/1257#issuecomment-2799959581)). We follow the established project-license convention, as [Docker's metadata action](https://github.com/docker/metadata-action/blob/master/src/meta.ts) does. Don't turn the label into a hand-maintained aggregate of dependency licenses. `/legal/README.md` and the registry descriptions state the scope: **Project files: CC0-1.0. Bundled third-party software: respective upstream licenses and terms; see /legal.**

## Image notices

Everything lives under `/legal` (layout in [`legal/README.md`](../legal/README.md)), generated at build by `scripts/collect-legal.sh`. `/legal/manifest.tsv` covers **every** redistributed component: the Debian base, apt packages, copied binaries, compiled components, release tarballs, installer downloads, and bundled dependencies, each with its license, notices, and exact source provenance. A version string alone can't establish which patches or dependencies went into a binary, so provenance is recorded as digests and checksums, not versions.

apt packages keep their notices at `/usr/share/doc/<pkg>/copyright`, and the manifest references them in place. Never delete them to trim the image. Notices aren't source: apt packages with copyleft licenses also get their source listed in `/legal/source.tsv`.

## How files get there

From most to least preferred:

1. **From the upstream image**, when the pinned upstream image ships the license. It matches the copied binary exactly.
2. **From the install artifact**, such as the `gh` release tarball, or the source a component was compiled from: git's `COPYING` and `LGPL-2.1` and zlib-ng's `LICENSE.md` come from the archives the `git` stage built, and the Rust standard library's notices from the toolchain that compiled it.
3. **Fetched from upstream at the installed version's tag**, when neither of the above ships it. Most copied tools ship only a binary, and Docker's `.deb`s ship no `copyright` file. Each fetched file's URL and SHA-256 are recorded in its `SOURCE` file. Nothing under `/legal/attribution` is committed, so notices can't drift from the binary, and a relicense shows up as a changed checksum.

Copied and compiled tools are described in `scripts/legal-components.yaml`. **Every ELF file in the image must belong to an apt package or a listed component, or the build fails.** A base image can ship binaries outside any package: Ubuntu's, which this image used before, shipped `/usr/bin/pebble` that way.

### SBOM coverage

`bake.yml` attaches an SPDX SBOM from BuildKit's Syft scanner. Syft identifies only what has metadata it reads (dpkg, `package.json`, `dist-info`, Go build info, `cargo auditable`, and a few version patterns). The build fills the gaps:

- **`/legal/sbom/devcontainer.cdx.json`** lists exactly the components Syft can't detect: standalone binaries without metadata, git and the zlib-ng compiled into it, and what's compiled into Node and Python's `pyexpat`. Syft merges it into the attestation. Only undetectable components go in it, because Syft doesn't merge an entry with a package it found itself, so listing one would duplicate it.
- **Docker's apt packages** get a machine-readable `copyright` file written from their fetched licenses, so Syft and Debian tooling can read them.
- **Go modules:** Syft looks up a module's license in any `pkg/mod/<module>@<version>/` directory. The build downloads every module compiled into the image's Go binaries through the verified Go proxy and keeps only their license files, under `/legal/go/pkg/mod/`. These double as the Go binaries' transitive notices. The first download is about 900 MB and takes about two minutes, cached afterwards.
- **`scripts/license-evidence.yaml`** covers modules whose notices name a license Syft can't see: a text in a subdirectory, under another name, or only linked. Reviewed texts are added beside the upstream files, never replacing them. Each entry pins the files it was reviewed against, so an upstream change fails the build until someone reviews it again.

Some of the attestation's license data is known to be wrong, and the build can't correct it: `manifest.tsv` and the notices are authoritative. Syft joins every license it finds with `AND` and can't read an election or "or later" (for example, `spdx/tools-golang` in dockerd shows GPL). It reports unclassifiable text as `LicenseRef-<sha256>`, which doesn't mean a license is missing. Version-pattern detections (go, node, python, jq) never get a license.

Builder stages aren't scanned (`BUILDKIT_SBOM_SCAN_STAGE`): they're full Debian images whose packages don't ship.

To inspect the attestation locally, export an OCI layout: `docker buildx bake image --allow fs.write=<dir> --set image.attest=type=sbom --set image.output=type=oci,dest=<dir>,tar=false`. A `type=local` export copies the whole root filesystem and stalled on macOS.

## Copyleft components

The image conveys GPL (v2 and v3), LGPL, and MPL-2.0 components: git (GPLv2, compiled here), MPL-2.0 Go modules in several tools and in Docker's binaries, and most of the Debian base and its packages, including Bash and coreutils. Being unmodified or installed with apt doesn't remove the redistribution obligations ([GNU FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#UnchangedJustBinary)).

**Policy: record, at build time, where the complete source of every GPL and LGPL component was published, and ship that list in the image as `/legal/source.tsv`.** Each file is listed by URL and digest, so a copy from anywhere else can be checked against it. The URLs point at upstream's servers, not ours ([`legal/SOURCE.md`](../legal/SOURCE.md)).

- **GPLv3 and LGPLv3** (§6(d)) accept Corresponding Source on a third-party server, with clear directions next to the object code, as long as the distributor makes sure it stays available for as long as the object code is offered.
- **GPLv2 and LGPL-2.x** accept equivalent access "from the same place" as the binary, and have no provision for a third-party server. A list of upstream's URLs is weaker than that, and that's a deliberate trade-off ([open questions](#open-questions)).
- **MPL-2.0** is file-level: it owes only the covered files' source. Every MPL-2.0 module in the image is compiled into a binary upstream built: betterleaks, dbmate, yq, and Task's release binaries, and Docker's packages. Redistributing those unchanged typically owes nothing more, as long as upstream complied ([MPL FAQ Q7](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)), so `source.tsv` doesn't list them. `manifest.tsv` still records each module's exact version and Go proxy archive. A binary compiled here would owe its MPL modules' source from us (Q8), so `collect-legal.sh` fails the build on a copyleft module in a `go install` component, and a Go tool with one is downloaded as upstream's release instead ([tooling.md](tooling.md#install-methods)).

**What's owed:** a GPL or LGPL binary owes its *whole* Corresponding Source, including permissive libraries compiled into it. An MPL module owes only itself. A dual license with a permissive option owes nothing once that option is elected, and elections are recorded in `scripts/license-elections.yaml`.

### `source.tsv`

`scripts/collect-source.sh` writes it in the `/legal` step, after `collect-legal.sh`, from that platform's `manifest.tsv`. Columns: source, version, URL, digest (`<algorithm>:<hex>`), and the `manifest.tsv` components the file covers. A copyleft component whose source can't be found fails the build.

- **apt packages:** every package whose license is copyleft, or `NOASSERTION` (a copyright file that isn't machine-readable, which can't rule it out), gets its source package at the exact source version installed: the `.dsc` and every archive it lists. apt resolves them from the `deb-src` repositories in `scripts/source-apt.yaml`, with a private configuration that leaves the image's own apt sources and lists alone, and checks the indexes against the repositories' signing keys. The digests are the strongest hash the signed index lists, SHA-512 for both repositories. The lists persist in a build cache mount, so a build fetches only what changed. Docker's apt repository publishes no source packages, and none of its packages is copyleft.
- **Compiled components** (`install: source-build`: git): the archive it was compiled from, the archives of the libraries compiled into it, and the build script, as a permalink at the build's commit when the build passes `REVISION` and `REPOSITORY_URL` (CI does), or its repository path otherwise.
- **Everything else** that's copyleft must be covered by an election, or the build fails.

The repositories the source comes from:

- **`dhi.io`**, Docker's hardened rebuilds (`+dhi` versions), for most of the base. Its index keeps some earlier versions, but there's no published retention policy, so an old version's URL can stop working.
- **Debian's archive** (`trixie` and `trixie-updates`) and **security archive** (`trixie-security`). A version leaves the archive when it's superseded, but [snapshot.debian.org](https://snapshot.debian.org) keeps every version Debian has published.

### Compiled components

A component compiled in the Dockerfile (`install: source-build`: git) records the source it was compiled from and the script that controlled the build, which a copyleft one owes. Its stage records both in `/legal/attribution/<name>/SOURCE`, and `collect-legal.sh` copies them into its manifest row:

- **The archive**, by URL and SHA-256: git's signed release tarball.
- **The build script**, by repository path and SHA-256 (`build-script:`): `scripts/build/git.sh`.
- **Libraries compiled in** (`embedded:`), each with a row of its own marked `embedded-in:<component>`: zlib-ng, under the Zlib license. A permissive license owes no source by itself, but a library compiled into a GPL binary is part of that binary's Corresponding Source, so `source.tsv` lists the archive of every library embedded in a copyleft component.

The Rust standard library is also compiled into git. It's Apache-2.0 OR MIT, so it owes no source, and its notices ship in `/legal/attribution/git/rust/`.

### Sandbox kits

A kit is the image it pins plus a few layers of its own: its descriptor, the git-ssh-sign key command with its Apache-2.0 license in `/legal/attribution/git-ssh-sign/`, and its agent from Docker's mixin, with the notices and `manifest.tsv` rows its `legal.sh` adds. The Claude kit adds Claude Code (Anthropic's terms, [below](#claude-code)). The Codex kit adds Codex (Apache-2.0) and the ripgrep it bundles (Unlicense OR MIT), and leaves out the package's LGPL parts: the voice libraries entirely, and its vendored bubblewrap, replaced by a copy of the image's own `bwrap` from Debian's `bubblewrap` package, which the image's `source.tsv` already lists. None of the kits' own layers is copyleft, so a kit owes the same source as its image and carries its `source.tsv` unchanged. A kit change that adds a copyleft component would need its `legal.sh` to list that component's source too.

## Transitive dependencies

Most components are static Go or Rust binaries that embed their dependencies, and many of those dependencies' licenses require their notices to travel with the binary. A tool's top-level `LICENSE` doesn't cover them. Go modules are covered through `/legal/go/pkg/mod/`. Rust crates aren't yet ([Open questions](#open-questions)). Adding or updating a dependency updates its notices and source coverage together.

## Claude Code

The image doesn't carry Claude Code. The Claude kit adds it, unmodified, from Docker's mixin, under Anthropic's [terms for offering Claude Code in products](https://code.claude.com/docs/en/legal-and-compliance#can-customers-offer-claude-code-in-their-products): its built-in authentication is preserved, and users authenticate with their own credentials. Don't resell or intermediate their usage, and follow the naming and branding conditions. The kit's build checks the binary against Anthropic's release manifest for the pinned version, and records Anthropic's `LICENSE.md` from the npm package of that version as `LicenseRef-Anthropic-Terms`, rather than an invented open-source license.

## Enforcement

- Missing inventory entries, notices, or fetched license files fail the build. `/legal/LICENSE` must match the root `LICENSE`.
- Every copyleft component's source is listed in `/legal/source.tsv`, on both architectures, or the build fails. Runtime test results are independent.
- Adding a component means adding its attribution in the same PR.

## Open questions

1. **Distribution compliance review.** Before the first public release, confirm whether a list of upstream's source URLs is acceptable for the GPLv2 and LGPL-2.x components, which provide for neither a third-party server nor this list, or whether they need source published with the image or a written offer; that `source.tsv` counts as §6(d) directions under GPLv3; and that upstream's published source covers the MPL-2.0 modules in the binaries it built. Also confirm coverage for the actual license versions and the recorded elections, complete transitive notices, and the Claude Code terms for this distribution. The project's CC0 dedication resolves none of these.
2. **Copyleft source gaps:**
   - **Unknown licenses:** the Rust crates in uv and in the kits' Codex, and whatever Claude Code bundles may add copyleft components.
   - **Availability:** `source.tsv`'s URLs depend on upstream keeping old versions, which `dhi.io` doesn't promise ([`source.tsv`](#sourcetsv)).
3. **License gaps** reported by `collect-legal.sh`, which doesn't fail on them yet:
   - Six npm modules bundled with pnpm ship only a `license` field, no license text.
   - jq's `COPYING` doesn't cover its bundled oniguruma.
   - Sixteen apt packages have copyright files that aren't machine-readable, so they're recorded as `NOASSERTION`. Most mention GPL or LGPL; zip and unzip (Info-ZIP) don't. `collect-source.sh` treats `NOASSERTION` as copyleft, so their source is listed regardless.
   - Transitive notices aren't collected yet for Rust binaries (uv, git-cliff, ripgrep, Codex).
