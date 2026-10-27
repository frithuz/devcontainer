# Legal notices and attribution

## Project license

This project's own code, configuration, and documentation are dedicated to the public domain under **Creative Commons Zero v1.0 Universal** (`CC0-1.0`, full text in [`LICENSE`](../LICENSE)). Third-party material, including everything installed or copied into the image, keeps its own licenses and terms.

### Impacts

- **Reuse:** anyone can copy, modify, and redistribute the project's work, commercially too, without attribution or publishing changes ([CC0 FAQ](https://wiki.creativecommons.org/wiki/CC0_FAQ#Does_CC0_require_others_who_use_my_work_to_give_me_attribution.3F)).
- **Permanence and limits:** the waiver is irrevocable for work already released, falls back to an unconditional license where a waiver isn't effective, and grants no patent or trademark license ([CC0 §§2–4](https://creativecommons.org/publicdomain/zero/1.0/legalcode.en)).
- **Software:** Creative Commons permits CC0 for software and calls it GPL-compatible ([FAQ](https://wiki.creativecommons.org/wiki/CC0_FAQ#May_I_apply_CC0_to_computer_software.3F_If_so.2C_is_there_a_recommended_implementation.3F)). The missing patent grant can still matter to downstream adopters.
- **Redistributed components:** CC0 for this project waives nothing on behalf of third parties. The image still owes upstream notices, GPL/LGPL/MPL source delivery, and compliance with proprietary terms. Everything below exists for that reason.
- **Contributions:** accepted under CC0-1.0. Contributors must have the authority to dedicate them, and imported material keeps its upstream terms.

### Packaging and metadata

The image copies `LICENSE` to `/legal/LICENSE` and records the project's own installed files under `CC0-1.0`, separately from third-party components. That copy is this project's packaging convention, not a condition CC0 imposes on anyone.

The image label `org.opencontainers.image.licenses="CC0-1.0"` describes **only the project's own contribution**. The OCI spec is ambiguous about whether this field means the project or everything inside the image ([image-spec#1257](https://github.com/opencontainers/image-spec/issues/1257#issuecomment-2799959581)). We follow the established project-license convention, as [Docker's metadata action](https://github.com/docker/metadata-action/blob/master/src/meta.ts) does. Don't turn the label into a hand-maintained aggregate of dependency licenses. Source images are different: their `licenses` annotation, where it's set, is generated from the licenses of the components they cover ([data model](data-model.md#source-image)). `/legal/README.md` and the registry descriptions state the scope: **Project files: CC0-1.0. Bundled third-party software: respective upstream licenses and terms; see /legal.**

## Image notices

Everything lives under `/legal` (layout in [`legal/README.md`](../legal/README.md)), generated at build by `scripts/collect-legal.sh`. `/legal/manifest.tsv` covers **every** redistributed component: the Debian base, apt packages, copied binaries, compiled components, release tarballs, installer downloads, and bundled dependencies, each with its license, notices, and exact source provenance. A version string alone can't establish which patches or dependencies went into a binary, so provenance is recorded as digests and checksums, not versions.

apt packages keep their notices at `/usr/share/doc/<pkg>/copyright`, and the manifest references them in place. Never delete them to trim the image. Notices aren't source: apt packages with copyleft licenses also get source images.

## How files get there

From most to least preferred:

1. **From the source image**, when the pinned upstream image ships the license. It matches the copied binary exactly.
2. **From the install artifact**, such as the `gh` release tarball, or the source a component was compiled from: git's `COPYING` and `LGPL-2.1` and zlib-ng's `LICENSE.md` come from the archives the `git` stage built, and the Rust standard library's notices from the toolchain that compiled it.
3. **Fetched from upstream at the installed version's tag**, when neither of the above ships it. Most copied tools ship only a binary, and Docker's `.deb`s ship no `copyright` file. Each fetched file's URL and SHA-256 are recorded in its `SOURCE` file. Nothing under `/legal/attribution` is committed, so notices can't drift from the binary, and a relicense shows up as a changed checksum.

Copied and compiled tools are described in `scripts/legal-components.yaml`. **Every ELF file in the image must belong to an apt package or a listed component, or the build fails.** A base image can ship binaries outside any package: Ubuntu's, which this image used before, shipped `/usr/bin/pebble` that way.

### SBOM coverage

`bake.yml` attaches an SPDX SBOM from BuildKit's Syft scanner. Syft identifies only what has metadata it reads (dpkg, `package.json`, `dist-info`, Go build info, `cargo auditable`, and a few version patterns). The build fills the gaps:

- **`/legal/sbom/devcontainer.cdx.json`** lists exactly the components Syft can't detect: standalone binaries without metadata, git and the zlib-ng compiled into it, Codex's bundled libraries, and what's compiled into Node and Python's `pyexpat`. Syft merges it into the attestation. Only undetectable components go in it, because Syft doesn't merge an entry with a package it found itself, so listing one would duplicate it.
- **Docker's apt packages** get a machine-readable `copyright` file written from their fetched licenses, so Syft and Debian tooling can read them.
- **Go modules:** Syft looks up a module's license in any `pkg/mod/<module>@<version>/` directory. The build downloads every module compiled into the image's Go binaries through the verified Go proxy and keeps only their license files, under `/legal/go/pkg/mod/`. These double as the Go binaries' transitive notices. The first download is about 900 MB and takes about two minutes, cached afterwards.
- **`scripts/license-evidence.yaml`** covers modules whose notices name a license Syft can't see: a text in a subdirectory, under another name, or only linked. Reviewed texts are added beside the upstream files, never replacing them. Each entry pins the files it was reviewed against, so an upstream change fails the build until someone reviews it again.

Some of the attestation's license data is known to be wrong, and the build can't correct it: `manifest.tsv` and the notices are authoritative. Syft joins every license it finds with `AND` and can't read an election or "or later" (for example, `spdx/tools-golang` in dockerd shows GPL). It reports unclassifiable text as `LicenseRef-<sha256>`, which doesn't mean a license is missing. Version-pattern detections (go, node, python, jq) never get a license.

Builder stages aren't scanned (`BUILDKIT_SBOM_SCAN_STAGE`): they're full Debian images whose packages don't ship.

To inspect the attestation locally, export an OCI layout: `docker buildx bake image --allow fs.write=<dir> --set image.attest=type=sbom --set image.output=type=oci,dest=<dir>,tar=false`. A `type=local` export copies the whole root filesystem and stalled on macOS.

## Copyleft components

The image conveys GPL (v2 and v3), LGPL, and MPL-2.0 components: git (GPLv2, compiled here), Codex's bubblewrap and GStreamer/GLib (LGPL), MPL-2.0 Go modules in several tools and in Docker's binaries, and most of the Debian base and its packages, including Bash and coreutils. Being unmodified or installed with apt doesn't remove the redistribution obligations ([GNU FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#UnchangedJustBinary)).

**Policy: publish the complete source of every copyleft component in the same registry repository as the image, before the image's tags are published.** One mechanism satisfies every license:

- **GPLv2 and LGPL-2.x** accept equivalent access to the source "from the same place" as the binary. There's no provision for a third-party server, so the source has to live with the image.
- **GPLv3 and LGPLv3** (§6(d)) accept Corresponding Source offered through the same place, with clear directions next to the object code. That's `/legal/SOURCE.md`.
- **MPL-2.0** is file-level: it owes only the covered files' source.

Publishing the source avoids written offers and their three-year commitments. Source stays available as long as its image does.

**What's owed:** a GPL or LGPL binary owes its *whole* Corresponding Source, including permissive modules compiled into it. An MPL module owes only itself. A dual license with a permissive option owes nothing once that option is elected, and elections are recorded in `scripts/source-roots.yaml`.

### Source images

Source is published as one **source image per root program per exact version**. A root program is the unit whose source is complete once it's fetched. A source image is a reproducible `FROM scratch` OCI image holding `/source/<root>/` and its provenance record ([data model](data-model.md#source-image)), so anyone can pull it with standard tools.

- **Reused across releases.** It's keyed by its identity (kind, root, exact reference, recipe revision), never by the image that uses it. An unchanged component is never collected or uploaded twice.
- **Immutable.** An absent `source-*` tag is pushed. An existing tag with the expected digest is reused, and anything else fails without overwriting.
- **Recipe changes rebuild everything.** The key includes `scripts/build-source-image.sh`'s digest and last commit, so changing the script changes every key. So does bumping `annotations_version` in `scripts/plan-sources.sh`, which is how changed annotations (such as each source image's description) reach the images already published. The fetch environment isn't in the key. If it ever changed the output, the immutability check would catch it as a conflict.

Roots come from each platform's `manifest.tsv`. apt packages need no configuration: `scripts/source-apt.yaml` maps their repositories to source repositories. Only non-apt roots, gaps, and elections are listed in `scripts/source-roots.yaml`. Every copyleft component has to be covered by one of these, or planning fails. Go modules' licenses aren't in the manifest, so the Go programs that owe source are listed by hand. Quirks:

- **Docker's apt repository publishes no source packages**, so moby, buildx, containerd, and runc are fetched from upstream git at the exact commit their binaries record. moby records an abbreviated commit, and gomplate and betterleaks record none, so those are trusted by tag.
- **Go roots** are vendored, and every module the binaries report has to appear in `vendor/modules.txt` at the same version.
- **apt packages come from three repositories**: Docker's hardened rebuilds (`dhi.io`, which publishes `deb-src` for its `+dhi` versions), Debian's archive, and Debian's security archive. Only `trixie` is mapped for the archive: `trixie-updates` publishes only `Sources.xz`, which the planner can't read, and today holds only `tzdata`, which comes from `dhi.io`. `trixie-security` has the same limitation, and no installed package comes from it today. A package from either fails planning rather than going uncovered.
- **Codex** is a `bundle`: a sparse checkout of its vendored bubblewrap and voice build scripts, plus the archives its `sources.json` lists.
- **git** is a `bundle` too ([compiled components](#compiled-components)).
- **Gaps** are reported on every run but don't fail it, so they stay visible until they're resolved. There are none today.

### Compiled components

A component compiled in the Dockerfile (`install: source-build`, so far only git) owes the source it was compiled from and the script that controlled the build. Its stage records both in `/legal/attribution/<name>/SOURCE`, and `collect-legal.sh` copies them into its manifest row:

- **The archive**, by URL and SHA-256: git's signed release tarball.
- **The build script**, by repository path and SHA-256 (`build-script:`): `scripts/build/git.nu`. Planning checks the checkout's copy against that digest and fails if it differs, so source is always planned from the image's own commit. The script goes into the source image under `build/`, and its digest is part of the key: the source image changes only when the script or a version does, not on every commit.
- **Libraries compiled in** (`embedded:`), each with a row of its own marked `embedded-in:<component>`: zlib-ng, under the Zlib license. A permissive license owes no source by itself, but a library compiled into a GPL binary is part of that binary's Corresponding Source, so the planner adds the archive of every library embedded in a covered copyleft component. Codex's bundled libraries aren't affected: Codex isn't copyleft.

git's source image holds the git tarball, zlib-ng's archive, `git.nu`, and git's `COPYING` and `LGPL-2.1` from the release's tag. The Rust standard library is also compiled into git. It's Apache-2.0 OR MIT, so it owes no source, and its notices ship in `/legal/attribution/git/rust/`.

### Building source images

`source.Dockerfile` and the Bake targets build source images the same way locally and in CI, with only Docker on the host. `scripts/build-sources.sh` drives it locally and runs under macOS's bash 3.2. The steps:

1. **Manifests**, exported by `preflight` or copied from a built image (`--from-image`).
2. **Plan** (`source-plan`) resolves every root's exact inputs and key. It's never cached, because upstream state can change without any build input changing. With `SOURCE_REUSE=<repository>`, already-published tags with the same key are skipped.
3. **Build** the generated `sources` group, written as OCI layouts locally or pushed with `SOURCE_PUSH=true`.

### Publishing

Both registries distribute the image, so **both carry the same source images and source indexes**. The order guarantees that no public tag points at an image before its complete source is in the same repository:

1. `build` pushes the image to GHCR under its recovery tag only.
2. `sources` builds the missing source images, then attaches **one source index per subject** (`scripts/source-indexes.sh`): the image index and each platform manifest. A source index is an OCI referrer listing, by digest, the source images that subject needs.
3. GHCR is tagged. `promote` copies the image with its referrers to Quay by digest, which carries the source along, then confirms and tags. Only GHCR has `source-*` tags. Quay reaches its source images through the source indexes.

The untagged image is reachable by digest as soon as it's pushed, like any manifest, but consumers find images through tags.

**Sandbox kits** are published to their own repositories ([maintenance.md](maintenance.md#publishing-the-kits)). A kit is the image it pins plus a few layers of its own: its descriptor, and the git-ssh-sign key command with its Apache-2.0 license in `/legal/attribution/git-ssh-sign/`. None of them is copyleft, so a kit owes the same source as its image. Each kit is pushed to GHCR untagged. `scripts/source-indexes.sh inherit` then checks that each platform manifest's layers start with the base image's for that platform. It copies the base's source images into the kit's repository with their `source-*` tags, and gives each kit subject the source index of the base's matching subject. Only then is the kit tagged, and `promote` carries it to Quay the same way. A kit change that adds a copyleft component would need its own source plan, so `inherit` isn't enough for it.

**Why one source index per subject:** Quay implements the OCI Referrers API natively. GHCR doesn't, so referrers live in a fallback index under the tag `sha256-<digest>`. Adding a second referrer rewrites that index, the client then tries to delete the old one, and GHCR rejects registry `DELETE`s with 405. So each subject gets exactly one source index, attached once, and a retry validates the existing index instead of attaching again. On Quay, `oras` runs with `--distribution-spec v1.1-referrers-api`, so a Quay-side problem fails loudly instead of silently creating fallback tags.

### Finding the source

[`legal/SOURCE.md`](../legal/SOURCE.md), shipped as `/legal/SOURCE.md`, gives the directions next to the object code. The same text goes in both registries' repository descriptions. The image can't know its own digest, so the directions start from the digest the user pulled. `oras` ships in the image so they work from inside it.

### Retention

Nothing expires today. Images, source images, source indexes, and publication history are kept in both registries indefinitely. Any future cleanup must keep source **at least as long as every retained image that references it, in each registry**:

- Source images are shared by many releases. Delete one only when no retained image's source index lists it.
- Source indexes on Quay are untagged and linked only by `subject`, and Quay's source images are untagged, reached only through the source indexes that list them. On GHCR source indexes are reached through `sha256-*` fallback tags, so keep those tags as long as their subject.
- Platform manifests can be shared between releases. Compute reachability from all retained publications before deleting anything, and never cascade-delete a release's children.

Test failures never trigger deletion.

## Transitive dependencies

Most components are static Go or Rust binaries that embed their dependencies, and many of those dependencies' licenses require their notices to travel with the binary. A tool's top-level `LICENSE` doesn't cover them. Go modules are covered through `/legal/go/pkg/mod/`. Rust crates aren't yet ([Open questions](#open-questions)). Adding or updating a dependency updates its notices and source coverage together.

## Claude Code

Claude Code is **preinstalled** under Anthropic's [terms for offering Claude Code in products](https://code.claude.com/docs/en/legal-and-compliance#can-customers-offer-claude-code-in-their-products): the binary stays unmodified, its built-in authentication is preserved, and users authenticate with their own credentials. Don't resell or intermediate their usage, and follow the naming and branding conditions. Its notice is Anthropic's `LICENSE.md` from the npm package of the installed version, recorded as `LicenseRef-Anthropic-Terms` rather than an invented open-source license.

## Enforcement

- Missing inventory entries, notices, or fetched license files fail the build. `/legal/LICENSE` must match the root `LICENSE`.
- Every copyleft component maps to a source image in the same repository, on both architectures, before public tags are applied. Source collection errors fail the `sources` job. Runtime test results are independent.
- Adding a component means adding its attribution in the same PR.

## Open questions

1. **Distribution compliance review.** Before the first public release, confirm that source images in the image's own repository, linked by a source index, count as "the same place" under GPLv2/LGPL-2.x and as §6(d) directions under GPLv3. Also confirm coverage for the actual license versions and the recorded elections, complete transitive notices, and the Claude Code terms for this distribution. The project's CC0 dedication resolves none of these.
2. **Copyleft source gaps:**
   - **Unknown licenses:** the Rust crates in uv, nushell, and Codex, and whatever Claude Code bundles may add copyleft roots.
3. **License gaps** reported by `collect-legal.sh`, which doesn't fail on them yet:
   - Ten bundled npm/pnpm modules ship only a `license` field, no license text.
   - jq's `COPYING` doesn't cover its bundled oniguruma.
   - Sixteen apt packages have copyright files that aren't machine-readable, so they're recorded as `NOASSERTION`. Most mention GPL or LGPL; zip and unzip (Info-ZIP) don't. Source planning treats `NOASSERTION` as copyleft, so their source is published regardless.
   - Transitive notices aren't collected yet for Rust binaries (uv, git-cliff, nushell, ripgrep, Codex).
