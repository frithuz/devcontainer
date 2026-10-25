# Legal notices and attribution

## Project license

This project's own code, configuration, and documentation are dedicated to the public domain under **Creative Commons Zero v1.0 Universal**, SPDX identifier `CC0-1.0`. The complete, unmodified legal text is in [`LICENSE`](../LICENSE). This covers the project's original Dockerfiles, scripts, workflows, sandbox kits, and documentation as they are added. Third-party material, including vendored files and software installed or copied into the image, retains its own licenses and terms.

### Impacts

- **Reuse:** anyone can copy, modify, and redistribute the project's own work, including commercially, without attribution or a requirement to publish changes. See the [CC0 deed](https://creativecommons.org/publicdomain/zero/1.0/) and [attribution FAQ](https://wiki.creativecommons.org/wiki/CC0_FAQ#Does_CC0_require_others_who_use_my_work_to_give_me_attribution.3F).
- **Permanence and limits:** CC0 waives copyright and related rights to the extent permitted by law, with an unconditional license fallback where the waiver is ineffective. It is irrevocable for work already released under it. It provides no patent or trademark license and disclaims warranties. See [CC0 §§2–4](https://creativecommons.org/publicdomain/zero/1.0/legalcode.en).
- **Software compatibility:** Creative Commons explicitly permits CC0 for software and describes it as compatible with the GPL. The absence of a patent grant remains relevant to downstream adoption. See the [CC0 software FAQ](https://wiki.creativecommons.org/wiki/CC0_FAQ#May_I_apply_CC0_to_computer_software.3F_If_so.2C_is_there_a_recommended_implementation.3F).
- **Redistributed components:** choosing CC0 for this project does not waive third-party rights. The image still needs upstream notices, applicable GPL/LGPL source delivery, and compliance with proprietary terms. The source images, retention rules, and distribution review below remain necessary. See the [CC0 guidance on third-party rights](https://wiki.creativecommons.org/wiki/CC0_FAQ#Who_can_use_CC0.3F).
- **Contributions:** original contributions are accepted under CC0-1.0. Contributors must have authority to dedicate them; imported material must retain its upstream terms and be identified separately. The repository license cannot dedicate someone else's rights.

### Packaging and metadata

When implementing the image, copy the root `LICENSE` verbatim to `/legal/LICENSE`. Explain its project-only scope in `/legal/README.md` and record the project's installed files in `/legal/manifest.tsv` under `CC0-1.0`, separately from third-party components. Keeping a copy in the image is this project's packaging convention, not an attribution condition imposed on downstream users by CC0.

Set the Docker image's project-level license metadata to:

```dockerfile
LABEL org.opencontainers.image.licenses="CC0-1.0"
```

`CC0-1.0` is the [registered SPDX identifier](https://spdx.org/licenses/CC0-1.0.html). Use the same value when emitting the corresponding OCI manifest or index annotation. This follows the repository-license convention implemented by [Docker's metadata action](https://github.com/docker/metadata-action/blob/master/src/meta.ts), which populates this field from the repository's SPDX license identifier.

The [OCI specification](https://github.com/opencontainers/image-spec/blob/main/annotations.md#pre-defined-annotation-keys) describes this field as licenses of contained software but does not clearly distinguish the project's license from every dependency's license. [OCI discussion #1257](https://github.com/opencontainers/image-spec/issues/1257#issuecomment-2799959581) acknowledges that ambiguity and the established project-license usage, including [images built for CI and base-image projects](https://github.com/opencontainers/image-spec/issues/1257#issuecomment-2805587869). Our choice is to follow that convention; it is not a claim that the specification mandates this interpretation.

Here the label identifies this project's own contribution and any rights it holds in the collection. It does not relicense Ubuntu, installed tools, or their dependencies. Keep their individual licenses, notices, and source obligations in `/legal/manifest.tsv` and the accompanying files. Do not turn the label into a hand-maintained aggregate expression of dependency licenses. `/legal/README.md` and registry descriptions must explain the scope: **Project files: CC0-1.0. Bundled third-party software: respective upstream licenses and terms; see /legal.**

The image build copies the project license and notices and generates `/legal/manifest.tsv` (see [How files get there](#how-files-get-there)). The source images are planned and built from those manifests, locally or in CI ([Building source images](#building-source-images)). Attaching source indexes and the stricter packaging checks described here are still implementation requirements, not completed behavior.

## Image notices

The image redistributes binaries from many upstream projects, so it carries their license and notice files with it. Everything lives under one root directory:

```text
/legal/
├── README.md                    # What this directory is and how it's laid out
├── LICENSE                      # This project's CC0-1.0 text; not a license for third-party components
├── SOURCE.md                    # Where to get Corresponding Source for copyleft components (OCI referrers)
├── manifest.tsv                 # Generated at build: component, version, architecture, license, notices, exact source
├── sbom/devcontainer.cdx.json   # Generated at build: CycloneDX entries for components SBOM scanners can't identify
├── provenance/                  # Build-time evidence (apt .deb URLs and checksums)
├── go/pkg/mod/<module>@<ver>/   # License files of every Go module compiled into the image
└── attribution/
    └── <component>/             # One directory per component (go, node, python, uv, hadolint, ...)
        ├── LICENSE*             # Verbatim upstream license file(s)
        ├── NOTICE*              # Verbatim upstream NOTICE / third-party notices, when the project ships them
        └── SOURCE               # Upstream repository, license path, SPDX ID, and source location for copyleft components
```

**Scope:** the inventory covers every redistributed component: the Ubuntu base, apt packages, copied binaries, release tarballs, standalone installers, and bundled dependencies. Tools remain preinstalled. License and source collection is part of packaging them for public distribution.

Packages installed with apt keep their notices at `/usr/share/doc/<pkg>/copyright`; `/legal/manifest.tsv` records those paths without duplicating the files. Never delete them when trimming documentation. Notices alone do not provide Corresponding Source: apt and base-image packages with source-distribution requirements are included in the source inventory and bundles too.

## How files get there

From most to least preferred:

1. **From the source image.** If the pinned upstream image contains the project's license files, `COPY --from=<stage>` them into `/legal/attribution/<component>/`. These match the copied binary exactly. Examples: `/usr/local/go/LICENSE` and `PATENTS`, and Python's `LICENSE.txt`.
2. **From the install artifact.** For release tarballs, such as `gh`, collect license files from what was actually installed. The Codex package ships notices only for its voice libraries (`codex-resources/voice/NOTICE.md` and `licenses/`), which are referenced in place.
3. **Fetched from upstream at build, for the installed version.** When neither the image nor the install artifact ships the license, `scripts/collect-legal.sh` downloads it from the upstream repository at the tag matching the installed version and records each file's upstream path, URL, and SHA-256 in `SOURCE`. This covers images that ship only a binary (node, uv, oras, hadolint with its `ThirdPartyNotices.txt`, shfmt, yq, gomplate, golangci-lint, betterleaks, git-cliff, and pnpm, listed with their repositories in `scripts/legal-components.yaml`), Codex (`LICENSE`, `NOTICE`) and the bubblewrap and ripgrep it bundles, and Docker's apt packages (`docker-ce`, `docker-ce-cli`, `docker-buildx-plugin`, `docker-compose-plugin`), which ship no `copyright` file. Claude Code's notice is Anthropic's `LICENSE.md` from the `@anthropic-ai/claude-code` npm package of the installed version, checked against the registry's integrity hash; the installed binary is checked against the release `manifest.json` checksum. Nothing under `/legal/attribution` is committed: the repository's `legal/` holds only `README.md` and `SOURCE.md`, and git ignores the generated paths. Because the files always come from the installed version's tag, they can't drift from the binary, and a relicense shows up in the next build's `SOURCE` checksums.

Every ELF file in the image must belong to an apt package or a component listed in `scripts/legal-components.yaml`; `collect-legal.sh` fails the build otherwise. That's how `/usr/bin/pebble`, which Ubuntu's base image ships outside any package, was found; it's listed under the `base` stage.

`scripts/collect-legal.sh` gathers install-artifact files and writes `/legal/manifest.tsv`. Each row records the component, installed version, architecture, license identifier, notice locations, and exact source provenance. For apt/base packages, query the installed package database and record the binary package version, source package name and version, origin, and source archive checksums. For copied tools, include the pinned upstream image digest and release/build provenance. A version string alone cannot establish which patches or dependencies were compiled into a binary. Collection runs as root after all installations, so the agent CLIs are covered too.

How the implementation records each kind of component:

- **Copied tools** are listed in `scripts/legal-components.yaml` (stage, license, version command, notice files, and the upstream license files to fetch). Pinned digests are read from the `Dockerfile`, so they live in one place. Tools built with `go install` at a pinned version (`install: go-install`, only `jv`) are recorded with the module, version, and `go.sum` hash from the binary's build info. A missing notice file fails the build.
- **apt and base packages:** the Docker Engine install step, the last apt step, saves `apt-get download --print-uris` for every installed package to `/legal/provenance/apt-uris.txt`, giving each `.deb`'s exact URL and SHA-512. The manifest records the source package and version alongside it. Licenses come from the `License:` fields of machine-readable (DEP-5) copyright files; other copyright files are recorded as `NOASSERTION`, with their path as the notice. These are Debian short names, not SPDX expressions.
- **Bundled dependencies:** npm's and pnpm's bundled `node_modules`, ripgrep, bubblewrap, and Codex's voice libraries (versions, URLs, and SHA-256s from its `sources.json`) each get their own row.

`manifest.tsv` columns: `component`, `version`, `architecture`, `license`, `notices` (space-separated paths), `source` (provenance).

### SBOM coverage

`bake.yml` attaches an SPDX SBOM generated by BuildKit's Syft scanner. It identifies components from what's in the final image: the dpkg database, npm `package.json` files, Python `dist-info`, Go build info embedded in Go binaries (with their full module lists), dependency data embedded by `cargo auditable` (uv, sudo-rs), and version patterns in a few known binaries (go, node, python, jq). It can't identify standalone binaries without such metadata, or anything downloaded at build time: hadolint, git-cliff, pnpm, Claude Code, Codex, and the ripgrep, bubblewrap, and voice libraries bundled with Codex.

Syft also reads SBOM files it finds in the image. `collect-legal.sh` therefore writes `/legal/sbom/devcontainer.cdx.json`, a CycloneDX 1.6 document with exactly those components: version, purl, SPDX license expression, SHA-256 of the installed binary, the installed path, and VCS/distribution URLs (with the source archive SHA-256 for the voice libraries). The file is deterministic, with no serial number or timestamp. Syft merges its components into the attestation with their licenses, but not their hashes, which stay in the file. Copied tools opt in with a `purl` in `scripts/legal-components.yaml`.

Only components Syft can't detect belong in the file: Syft doesn't merge an entry with a package it detected itself, so listing, for example, `node` would produce a duplicate. The file also lists what's compiled into binaries without metadata Syft can read: the libraries node reports in `process.versions` (OpenSSL, ICU, V8, libuv, and others, with CPEs so vulnerability scanners match them), the expat bundled into Python's `pyexpat`, and this project itself.

For components Syft detects, the build puts license files where Syft looks for them:

- **apt packages without a copyright file** (Docker's four packages): `collect-legal.sh` writes a Debian machine-readable `/usr/share/doc/<package>/copyright` from the license files fetched at the installed version's upstream tag. Syft and Debian tooling read the license from it.
- **Go modules:** Syft looks up a module's license in any `…/pkg/mod/<module>@<version>/` directory in the image. `collect-legal.sh` lists every module compiled into the image's Go binaries (`go version -m`, including Docker's and Ubuntu's), downloads each through the Go proxy, verified against `sum.golang.org`, into a build cache mount, and keeps only its license and notice files under `/legal/go/pkg/mod/`, outside the live `GOPATH`. It keeps them from every directory of the module, at their upstream paths, since subdirectories often hold code under another license (forked Go code, for example). License-named files that aren't documents are skipped: Go source, scripts, config files, and anything in hidden directories such as `.github/`. These are also the transitive notices the Go binaries need (see [Transitive dependencies](#transitive-dependencies)). A main module that reports `(devel)` gets its version (and, for a binary built from a file list, its path) from a `-X …Version=` linker flag, as Syft infers it; a module the proxy can't serve (pebble's unpublished commit) falls back to a component's fetched attribution for the same repository. The first download is about 900 MB and two minutes; the layer is reused until its inputs or the refresh argument change.
- **Go modules whose notices name another license:** Syft reads only license-named files at the top of a module's directory. A license whose text a module keeps in a subdirectory (`spdy/LICENSE`), under another name (`GO_LICENSE`), or only links from its NOTICE is therefore missing from the attestation. `scripts/license-evidence.yaml` lists these modules after review. For each one, `collect-legal.sh` copies the module's own text, or downloads a pinned text checked against its SHA-256, to the top of the module's directory, beside the upstream files. It never replaces or removes them. Each entry pins the upstream files it was reviewed against by SHA-256, so a changed file fails the build until the entry is reviewed again. A version of the module that has none of those files (one that predates the code) is skipped and logged, and an entry no version applies to fails the build. `manifest.tsv` records each added file and where it came from (`added:<name>=<path or URL>`). A NOTICE Syft can't classify still shows up as a `LicenseRef-<sha256>` alongside the module's licenses: that's Syft reporting a file it can't classify, not a missing license.

What remains without a license in the attestation, and why: binaries Syft identifies only by version pattern (go, node, python, jq) never get one; Rust crates (uv's, from `cargo auditable`) have no license source Syft reads; packages pip's own SBOM lists carry none; and the Go toolchain's `cmd/*` entries are the standard library. Their licenses are in `manifest.tsv`.

Known to be wrong in the attestation, checked against upstream (deps.dev for packages, the license files at the installed tags for everything else) on 2026-10-25. Syft produces these, so the build can't correct them; `manifest.tsv` and the notices are right:

- **`github.com/spdx/tools-golang`** (in dockerd) reads `Apache-2.0 AND CC-BY-4.0 AND GPL-2.0-only`. Its `LICENSE.code` is `Apache-2.0 OR GPL-2.0-or-later` (Apache-2.0 is elected in `scripts/source-roots.yaml`); CC-BY-4.0 covers only its docs. Syft joins every license it finds with `AND` and can't read a choice or "or later" from the text.
- **`qrcode-terminal`** (bundled with npm) reads `LicenseRef-Apache-2.0`: its `package.json` uses the deprecated `licenses: [{"type": "Apache 2.0"}]` form. Its `LICENSE` is Apache-2.0, as `manifest.tsv` records.
- **Thirteen apt packages** whose copyright files aren't machine-readable (gcc-16's runtime libraries, libcrypt1, libgcrypt20, libgnutls30t64, krb5's libraries, libtasn1-6, ubuntu-keyring) carry only `LicenseRef-<sha256>` entries, Syft's name for text it can't classify, not an identified license.
- **Go modules whose upstream lists more licenses** (`cloud.google.com/go`, `hcsshim`, `cfssl`, `minlz`, `kube-openapi`, and a few others) differ because deps.dev counts license files in every subdirectory. None of that code is linked into an image binary; the one subdirectory that is (`k8s.io/client-go/third_party/forked/golang`) is covered by `scripts/license-evidence.yaml`.

Scanning builder stages (`BUILDKIT_SBOM_SCAN_STAGE`) isn't used: the builder stages are full Debian images whose packages aren't shipped.

To check coverage locally, export an OCI layout and read the attestation: `docker buildx bake image --allow fs.write=<dir> --set image.attest=type=sbom --set image.output=type=oci,dest=<dir>,tar=false`. Exporting with `type=local` copies the whole root filesystem to the host and stalled on macOS.

`/legal` is `root:root`, world-readable, and read-only for `agent`.

The [data model draft](data-model.md) proposes concrete inventory, source-image, and source-index schemas, including authoritative JSON with a generated TSV summary. The interface changes remain a proposal until implementation adopts them.

## Component licenses

The repository-level licenses as reported by GitHub. Each one has to be confirmed against the actual file shipped with the pinned version.

| Component | License | Source of files | Notes |
| --- | --- | --- | --- |
| Go | BSD-3-Clause | image (`LICENSE`, `PATENTS`) | |
| Node.js | MIT + bundled deps | fetched at build | The `node` slim image doesn't ship Node's `LICENSE`. It includes the licenses of Node's bundled dependencies |
| npm | Artistic-2.0 + bundled deps | image (in place) | Bundled with Node; each bundled module's notices are referenced in place |
| Python | PSF-2.0 | image (`LICENSE.txt`) | pip (MIT) is recorded separately, with its notices in place |
| uv | MIT OR Apache-2.0 | fetched at build | Both license files |
| pnpm | MIT (+ bundled deps) | fetched at build; image for `dist/node_modules/*` | The image ships only the binary and its bundled `dist/node_modules` |
| hadolint | **GPL-3.0** | fetched at build (+ `ThirdPartyNotices.txt`) | Copyleft (see below). Recorded as `GPL-3.0-only`; upstream states no "or later" |
| shfmt | BSD-3-Clause | fetched at build | |
| jq | MIT AND ICU AND BSD-2-Clause AND dtoa | image (`/COPYING`) | `COPYING` covers jq, decNumber (ICU), dtoa, and the Heimdal and NetBSD code (BSD-2-Clause), but not the oniguruma built into the binary (also BSD-2-Clause) |
| yq | MIT | fetched at build | |
| jv | Apache-2.0 | `jv` stage (the module's `LICENSE`, verified by `go.sum`) | Built with `go install` at a pinned version; the manifest records the module, version, and hash from the binary's build info |
| gomplate | MIT | fetched at build | |
| golangci-lint | **GPL-3.0** | fetched at build | Copyleft (see below). Recorded as `GPL-3.0-only`; upstream states no "or later" |
| betterleaks | MIT | fetched at build | |
| git-cliff | MIT OR Apache-2.0 | fetched at build | Both license files |
| GitHub CLI | MIT | release tarball | |
| oras | Apache-2.0 | fetched at build | The image ships no license file |
| Codex | Apache-2.0 | fetched at build (`LICENSE`, `NOTICE`) | Bundles bubblewrap (LGPL-2.0-or-later, vendored in `openai/codex` at `codex-rs/vendor/bubblewrap`), ripgrep (Unlicense OR MIT), and voice libraries: GStreamer and GLib (LGPL-2.1-or-later), proxy-libintl (LGPL-2.0-or-later), PCRE2, Opus, libffi, zlib |
| Docker Engine packages | Apache-2.0 | fetched at build | Docker's `.deb`s ship no `copyright` file; `containerd.io` does |
| Claude Code | **Proprietary** | fetched at build (`LICENSE.md` from the npm package of the installed version) | Preinstalled under the applicable Anthropic terms (see below) |

This table lists the primary non-apt tools. The generated inventory additionally covers all installed distro packages and bundled dependencies, with their individual licenses.

## Copyleft components

The image conveys components under copyleft licenses: GPL (v2 and v3), LGPL, and MPL-2.0. Among them are hadolint, golangci-lint, and pebble (GPLv3), the bubblewrap and GStreamer/GLib libraries bundled with Codex (LGPL), MPL-2.0 Go modules compiled into gomplate, yq, betterleaks, and Docker's binaries, and most of the Ubuntu base and apt packages, including Bash and Git. Being unmodified or installed through apt does not remove redistribution obligations. See the [GNU FAQ on redistributing downloaded binaries](https://www.gnu.org/licenses/gpl-faq.en.html#UnchangedJustBinary).

**Policy: mirror the complete source of every copyleft component, in the same registry repository as the image, before the image's tags are published.** One mechanism covers every license:

- **GPLv2 and LGPL-2.x:** §3(a) (LGPL §6(a)) lets the distributor accompany the binary with the complete source. When distribution is by "offering access to copy from a designated place", offering equivalent access to the source "from the same place" counts as distributing it. GPLv2 has no provision for a third-party server, so the source lives with the image. "Complete source code" includes "the scripts used to control compilation and installation".
- **GPLv3 and LGPLv3:** §6(d) is satisfied by offering the Corresponding Source through the same place, with clear directions next to the object code.
- **MPL-2.0:** §3.2 requires the source of the covered files to be available with the executable. MPL is file-level, so only the MPL modules' own source is required, though the root-program source images below include more.

Mirroring avoids written offers and their three-year commitments. Source stays available for as long as its image is ([Retention](#retention)).

**What source is owed.** A GPL or LGPL binary owes its **whole** Corresponding Source: everything compiled into it, including permissively licensed modules. golangci-lint, for example, owes the source of all 208 of its Go modules. An MPL-2.0 module owes only its own source. A component under a dual license that includes a permissive option owes none, once that option is elected. Elections are recorded in `scripts/source-roots.yaml` (for example node's bundled zstd, `BSD-3-Clause OR GPL-2.0-only`, and `spdx/tools-golang` in dockerd, `Apache-2.0 OR GPL-2.0-or-later`).

### Source images

Source is published as one **source image per root program per exact version**. A root program is the unit whose source, once fetched, is complete on its own: "clone this to have all the source". Source images are reused across every image release that ships the same version, so an unchanged component is never collected or uploaded twice.

- **Format:** a regular OCI image built `FROM scratch`, holding `/source/<root>/` and `/source/SOURCE.json`, the provenance record ([data model](data-model.md#source-image)). Anyone can pull it with standard tools. It's built reproducibly (`SOURCE_DATE_EPOCH`, rewritten timestamps, deterministic tar), so identical inputs produce an identical digest.
- **Location and tag:** in the image's own repository, tagged `source-<root>-<version>-<key8>`. `<root>` and `<version>` are sanitized to the tag character set (`[A-Za-z0-9_.-]`, 128 characters at most). `<key8>` is the start of the SHA-256 of the canonical identity: kind, root, exact version, exact reference (commit, `.dsc` digest, or archive digests), and the revision of the recipe that builds it. A recipe change produces a new tag. The full key is an image annotation. Consumers' Dependabot ignores these tags: it only proposes tags with the same prefix and format as the pinned one.
- **Immutable:** an absent tag is built and pushed, an existing tag with the expected digest is reused, and a different digest fails without overwriting.

**Which roots, and how each gets its complete source.** Roots are derived from each platform's `/legal/manifest.tsv`. apt packages need no entry: `scripts/source-apt.yaml` maps each package's `.deb` URL to the source repository, suites, and signing keyring to fetch its source package from. Both architectures map to the same source repository, so they share source images. Only the non-apt roots need an entry in `scripts/source-roots.yaml` (name, kind, repository, tag pattern, the module and binaries or components it covers, and its dependency vendoring or subpaths). The same file records the documented gaps and the dual-license elections. Every copyleft component that isn't an apt package or a Go module has to be covered by a root, a gap, or an election, or planning fails. Go modules are recorded as `NOASSERTION`, so the Go programs that owe source are listed by hand.

| Root kind | Which components | Recipe | Verification |
| --- | --- | --- | --- |
| `apt` | Every Ubuntu or PPA package whose copyright lists a copyleft license, or isn't machine-readable. About 82 source packages, including git from the git-core PPA | `apt-get source --download-only <source>=<version>`: the `.dsc`, original archives, and Debian/Ubuntu packaging (patches and build scripts) | apt checks every file against the archive's signed `Sources` index. The planned digests (the `.dsc` digest is part of the key) are checked again, and the fetched file set must match exactly |
| `git` + `go` | Go programs owing source: golangci-lint (GPL), gomplate, yq, and betterleaks (MPL modules), and the Docker programs with MPL modules: moby (`dockerd`, `docker-proxy`), buildx, containerd, runc. Docker's apt repository publishes **no source packages**, so these come from upstream | Fetch the exact commit (`git fetch --depth 1 <commit>`), export with `git archive` (ignoring the repository's `export-ignore`), then vendor the dependencies (`go mod vendor`) unless the repository already commits `vendor/` (moby, buildx, containerd, runc do) | The tag's commit against the revision `collect-legal.sh` records for the main module in `manifest.tsv`: `vcs.revision`, or a `GitCommit`/`Revision` linker flag, which may be abbreviated (moby). gomplate and betterleaks record none and are trusted by tag. Every module `manifest.tsv` lists for the root's binaries must be in `vendor/modules.txt` at the same version. `SOURCE.json` records each vendored module's `go.sum` hash |
| `git` + `haskell` | hadolint (GPL) | The exact tag, plus every Haskell dependency at the version the release was built with, from Hackage | **Open:** the repository pins dependencies only through `cabal.project` and `devenv.lock`; the exact set has to come from the release build. Recorded as a gap in `scripts/source-roots.yaml` |
| `bundle` | The copyleft parts of Codex: bubblewrap (LGPL, vendored at `codex-rs/vendor/bubblewrap`), and the voice libraries (GStreamer, GLib, proxy-libintl; LGPL) | Sparse checkout of `codex-rs/vendor/bubblewrap` and `third_party/voice/` (the build scripts) at `rust-v<version>`, plus the source archives listed in the package's `sources.json` | Archive SHA-256s from `sources.json`; the commit against the tag |
| — | pebble (GPL, shipped unpackaged in Ubuntu's base image) | **Not available:** the commit in its build info (`2cbd1b20d20a`) isn't in `canonical/pebble` or on the Go proxy | Open question; recorded as a gap |

A source image contains the source as published (Debian source packages as their original files, git as an exported tree, archives as downloaded), plus the vendored dependencies. A root that can't be produced fails the `sources` job; the image stays untagged (see [Publishing](#publishing)). Gaps are reported on every run but don't fail it, so they stay visible until they're resolved.

### Building source images

`source.Dockerfile` and the bake targets in `docker-bake.hcl` build source images the same way locally and in CI. Everything runs in BuildKit, so only Docker is needed on the host:

1. **Manifests.** `docker buildx bake preflight` exports each platform's `manifest.tsv` to `out/preflight/`. For a quick local run, `scripts/build-sources.sh --from-image <image>` copies it out of an already built image instead.
2. **Plan.** The `source-plan` target runs `scripts/plan-sources.sh` on those manifests and never caches that step, since upstream state can change without any build input changing. It resolves every root's exact inputs and computes its key and tag, then exports `out/sources/`:
   - `plan.tsv`: every source image, gap, and election, with the components it covers.
   - `plans/<tag>/plan.json`: one per source image, the input to `build-source-image.sh`.
   - `sources.hcl`: a bake target per source image and the `sources` group.

   Anything unresolved fails it. With `SOURCE_REUSE=<repository>`, tags already published there with the same key are reused and left out of the group; a tag with a different key is an error.
3. **Build.** `docker buildx bake -f docker-bake.hcl -f out/sources/sources.hcl sources` builds them in parallel. Each fetch stage runs once on the build platform, and both platform manifests share its layer. `SOURCE_DATE_EPOCH=0` and `rewrite-timestamp` make the result reproducible: rebuilding the same plan gives the same index digest. Locally, each image is written as an OCI layout to `out/sources/oci/<tag>/`; with `SOURCE_PUSH=true` and `SOURCE_REPOSITORY=<registry>/<repo>`, it's pushed instead.

`scripts/build-sources.sh` runs steps 2 and 3 on the host (macOS's bash 3.2 included). It sets the recipe revision from git, and `--plan-only` and `--only <root>` narrow what it does. The recipe in each key is `scripts/build-source-image.sh`: its digest, and the last commit that changed it (`uncommitted` when it has local changes). Changing the script therefore changes every key. The fetch environment (`source.Dockerfile`'s pinned images) isn't part of the key. If an environment change ever changed the output, the immutable-tag check would catch it as a conflict.

### Publishing

Both registries distribute the image publicly, so **both carry the same source images and source indexes** (see [maintenance.md](maintenance.md#workflow)). The image is built once. Testing runs alongside source publication and promotion and does not control either.

1. **`build`** pushes the `image` target to GHCR under its recovery tag only (`build-<publication-id>`), with no public tags, recording the digest.
2. **`sources`** runs after `build`:
   1. Extract `/legal/manifest.tsv` from each platform image under the recorded digest, and derive the root programs and versions that owe source.
   2. For each root, compute its tag and check GHCR (`source-plan` with `SOURCE_REUSE`). Existing tags are reused; registry errors fail the check rather than counting as absent. Build and push only the missing ones, through the generated `sources` group with `SOURCE_PUSH=true`, in an environment separate from the runtime image.
   3. Attach **one source index per subject**: the image index, and each platform manifest (skipping `bake.yml`'s `unknown/unknown` attestation manifests). A source index is an OCI image index of artifact type `application/vnd.frithuz.devcontainer.source.v1`, with the subject set, listing that platform's source images by digest. The index's source index covers both platforms. Being in the same repository, the source images are part of the referrer's graph.
   4. A re-run validates an existing source index against the manifests before skipping its subject; a mismatch is a reported error.
3. **`promote`**, which depends on `sources` but not on tests, copies the image to Quay with its referrers (`oras cp -r`). That brings the source indexes and, through them, the source images, by digest, skipping blobs Quay already has. It confirms each subject's source index through Quay's Referrers API.
4. **Tags** are applied in both registries only after source is published in that registry: the date tag, `:latest`, and `:main` on GHCR after `sources`, and on Quay after `promote`.

No public tag points at an image before its complete source is in the same repository. The untagged image is reachable by digest from the moment it's pushed, as any pushed manifest is; consumers find images through tags.

**How each registry stores referrers:**

- **Quay** implements the OCI Referrers API natively. `GET /v2/<repo>/referrers/<digest>` returns an OCI image index, so artifacts are found through their `subject` link, with no tags involved. `--distribution-spec v1.1-referrers-api` makes `oras` use the API only, so a Quay-side problem fails loudly instead of silently creating fallback tags.
- **GHCR** has no Referrers API. Artifacts are listed in an index stored under the tag `sha256-<digest>`. GHCR rejects registry `DELETE`s with 405, so a subject's fallback index must never need rewriting. Hence one source index per subject, attached once, and re-runs that skip subjects that already have it.

### Finding the source

`/legal/SOURCE.md` in the image gives the directions next to the object code. `oras` ships in the image, so this works from inside the container. The image can't know its own digest at build time, so the instructions start from the digest the user pulled. The same commands work for either registry: `oras discover` uses the Referrers API on Quay and the tag fallback on GHCR.

```sh
image=<registry>/<repo>@<digest>
oras discover --artifact-type application/vnd.frithuz.devcontainer.source.v1 "$image"
oras manifest fetch "<registry>/<repo>@<source-index-digest>" | jq -r '.manifests[] | .digest + "  " + .annotations["org.opencontainers.image.title"]'
docker create --name source "<registry>/<repo>@<source-image-digest>" none
docker cp source:/source ./source && docker rm source
```

Each source image is also reachable by its `source-*` tag. The same directions appear in the Quay repository description and the GHCR package description.

### Retention

Until a retention policy is adopted, keep all published images, source images, source indexes, and publication history in both registries with no automatic expiry or age/count limit. Durable records and their evidence belong in the registries; GitHub workflow artifacts are temporary transport, not the long-term record store. See the [registry record draft](data-model.md#publication-intent).

Source has to stay available as long as the image is, **in each registry**. Any cleanup of old images, such as pruning old `:YYYYMMDD` snapshots, must keep source **at least as long as every image that references it**:

- **Source images** are tagged (`source-*`) and shared by many releases. Delete one only when no retained image's source index references it.
- **Source indexes on Quay** are untagged manifests linked to their image by `subject`. Never delete one while its subject is published.
- **Source indexes on GHCR** are reached through `sha256-<digest>` fallback tags. Keep those tags, and the versions they point to, for as long as their subject image is kept.

Determine reachability from all retained publications before deleting anything. A platform manifest can be shared by multiple releases. Never recursively delete a release's children merely because one index is removed. Test failures do not trigger deletion.

## Transitive dependencies

Most components are statically linked Go or Rust binaries. Those binaries embed their module dependencies, and many of those dependencies' licenses (MIT, BSD) require their notices to travel with the binary. The top-level `LICENSE` file doesn't cover them.

- Ship each component's license and the required notices for its bundled dependencies. Use upstream third-party notices when they cover the actual build; otherwise generate the missing notices from the exact dependency sources, for example with `go-licenses` or `cargo-about`.
- Required transitive notices are part of the initial packaging work. Adding or updating a dependency must update the notices and source inventory together.

## Claude Code

Claude Code stays **preinstalled**. Anthropic's [legal and compliance documentation](https://code.claude.com/docs/en/legal-and-compliance#can-customers-offer-claude-code-in-their-products) describes preinstallation under its Commercial Terms: keep the binary unmodified, preserve its built-in authentication methods, and have end users authenticate with their own credentials under the applicable terms. Do not resell or intermediate their usage. Follow the vendor's naming and branding conditions too.

`collect-legal.sh` records Anthropic's own notice (`LICENSE.md`, which points to the legal agreements at https://code.claude.com/docs/en/legal-and-compliance) in `/legal/attribution/claude/`, and uses a proprietary license reference (`LicenseRef-Anthropic-Terms`) in the inventory rather than inventing an open-source license. Confirm the distribution setup meets those terms before the first public release. Runtime installation is not the planned delivery method.

## Enforcement

- **Project license:** `/legal/LICENSE` must match the repository's root `LICENSE`, and the inventory must distinguish the project's `CC0-1.0` files from third-party components. `/legal/README.md` and registry descriptions must explain that scope.
- **Build inventory:** every component must have a license identifier and notice locations in `manifest.tsv`. Non-apt components have `/legal/attribution/<component>/` entries; apt/base packages reference their preserved copyright files. Proprietary tools record applicable terms and provenance. Missing inventory or required notices fail packaging.
- **Source collection:** every copyleft component maps to a root program whose source image exists in the same repository, verified as described in [Source images](#source-images), for both architectures, before public tags are applied. Collection errors fail the `sources` job and trigger recovery; runtime test results are independent.
- **Adding a component** requires adding its attribution in the same PR.
- **Fetched files:** license files are fetched from the upstream tag of the installed version on every build, so there are no committed copies to drift. A failed fetch fails the build. When Dependabot bumps a tool, review its `SOURCE` checksums in `/legal/attribution` for a license change.

## Open questions

1. **Distribution compliance review.** Before the first public release, confirm: source images in the image's own repository, linked by a source index, as "the same place" under GPLv2/LGPL-2.x and as §6(d) directions under GPLv3; coverage for the actual GPL/LGPL/MPL versions and the recorded dual-license elections; complete transitive notices; and the Claude Code terms for this distribution. The project's CC0 dedication does not resolve these questions.
2. **Copyleft source gaps:**
   - **pebble:** its exact source isn't public. Remove it from the image (which means not shipping Ubuntu's base layer unchanged), ship it and accept the gap, or ask Canonical to publish the commit.
   - **hadolint:** the exact Haskell dependency set of the release build has to be established before its source image can be built.
   - **Unknown licenses:** the licenses of uv's and Codex's Rust crates, hadolint's Haskell packages, and what Claude Code bundles haven't been determined, so they may add copyleft roots.
3. **License gaps found during implementation** (reported by `collect-legal.sh`, which doesn't fail on them yet):
   - Ten bundled npm/pnpm modules ship no license text, only a `license` field (`@npmcli/agent`, `@sigstore/verify`, `spdx-exceptions`, `spdx-license-ids`, `chownr`, `get-pnpm`, `isexe`, `minipass`, `tar`, `yallist`).
   - jq's `COPYING` doesn't cover its bundled oniguruma.
   - Thirteen apt packages (from seven source packages: gcc-16, libxcrypt, libgcrypt20, gnutls28, krb5, libtasn1-6, ubuntu-keyring) have copyright files that aren't machine-readable, so their license is `NOASSERTION`. All of them mention GPL or LGPL, so their source is mirrored regardless.
   - hadolint and golangci-lint ship a license text without an "or later" statement; `-only` is recorded pending review.
   - Transitive notices are collected for every Go module, but not yet for Rust binaries (uv, git-cliff, ripgrep, Codex) or Haskell (hadolint).
