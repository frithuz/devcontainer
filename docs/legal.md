# Legal notices and attribution

## Project license

This project's own code, configuration, and documentation are dedicated to the public domain under **Creative Commons Zero v1.0 Universal**, SPDX identifier `CC0-1.0`. The complete, unmodified legal text is in [`LICENSE`](../LICENSE). This covers the project's original Dockerfiles, scripts, workflows, sandbox kits, and documentation as they are added. Third-party material, including vendored files and software installed or copied into the image, retains its own licenses and terms.

### Impacts

- **Reuse:** anyone can copy, modify, and redistribute the project's own work, including commercially, without attribution or a requirement to publish changes. See the [CC0 deed](https://creativecommons.org/publicdomain/zero/1.0/) and [attribution FAQ](https://wiki.creativecommons.org/wiki/CC0_FAQ#Does_CC0_require_others_who_use_my_work_to_give_me_attribution.3F).
- **Permanence and limits:** CC0 waives copyright and related rights to the extent permitted by law, with an unconditional license fallback where the waiver is ineffective. It is irrevocable for work already released under it. It provides no patent or trademark license and disclaims warranties. See [CC0 §§2–4](https://creativecommons.org/publicdomain/zero/1.0/legalcode.en).
- **Software compatibility:** Creative Commons explicitly permits CC0 for software and describes it as compatible with the GPL. The absence of a patent grant remains relevant to downstream adoption. See the [CC0 software FAQ](https://wiki.creativecommons.org/wiki/CC0_FAQ#May_I_apply_CC0_to_computer_software.3F_If_so.2C_is_there_a_recommended_implementation.3F).
- **Redistributed components:** choosing CC0 for this project does not waive third-party rights. The image still needs upstream notices, applicable GPL/LGPL source delivery, and compliance with proprietary terms. The source bundles, retention rules, and distribution review below remain necessary. See the [CC0 guidance on third-party rights](https://wiki.creativecommons.org/wiki/CC0_FAQ#Who_can_use_CC0.3F).
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

The repository currently contains design documentation only. Image copying, inventory generation, and packaging checks described here are implementation requirements, not completed build behavior.

## Image notices

The image redistributes binaries from many upstream projects, so it carries their license and notice files with it. Everything lives under one root directory:

```text
/legal/
├── README.md                    # What this directory is and how it's laid out
├── LICENSE                      # This project's CC0-1.0 text; not a license for third-party components
├── SOURCE.md                    # Where to get Corresponding Source for copyleft components (OCI referrers)
├── manifest.tsv                 # Generated at build: component, version, architecture, license, notices, exact source
└── attribution/
    └── <component>/             # One directory per component (go, node, python, uv, hadolint, ...)
        ├── LICENSE*             # Verbatim upstream license file(s)
        ├── NOTICE*              # Verbatim upstream NOTICE / third-party notices, when the project ships them
        └── SOURCE               # Upstream repository, license path, SPDX ID, and source location for copyleft components
```

**Scope:** the inventory covers every redistributed component: the Ubuntu base, apt packages, copied binaries, npm packages, release tarballs, standalone installers, and bundled dependencies. Tools remain preinstalled. License and source collection is part of packaging them for public distribution.

Packages installed with apt keep their notices at `/usr/share/doc/<pkg>/copyright`; `/legal/manifest.tsv` records those paths without duplicating the files. Never delete them when trimming documentation. Notices alone do not provide Corresponding Source: apt and base-image packages with source-distribution requirements are included in the source inventory and bundles too.

## How files get there

From most to least preferred:

1. **From the source image.** If the pinned upstream image contains the project's license files, `COPY --from=<stage>` them into `/legal/attribution/<component>/`. These match the copied binary exactly. Examples: `/usr/local/go/LICENSE` and `PATENTS`, and Python's `LICENSE.txt`.
2. **From the install artifact.** For npm packages (`/opt/tools/node_modules/*/LICENSE*`) and release tarballs, such as `gh` and the Codex standalone package, collect license files from what was actually installed.
3. **Vendored in this repository.** For images that ship only a binary, such as distroless or `scratch` images like hadolint, shfmt, jq, gomplate, golangci-lint, betterleaks, git-cliff, and uv, commit the upstream license file under `legal/attribution/<component>/` in this repo. `COPY legal/ /legal/` brings them in. Each vendored file records in `SOURCE` the upstream path it was taken from.
`scripts/collect-legal.sh` gathers install-artifact files and writes `/legal/manifest.tsv`. Each row records the component, installed version, architecture, license identifier, notice locations, and exact source provenance. For apt/base packages, query the installed package database and record the binary package version, source package name and version, origin, and source archive checksums. For copied tools, include the pinned upstream image digest and release/build provenance. A version string alone cannot establish which patches or dependencies were compiled into a binary. Collection runs as root after all installations, so the agent CLIs are covered too.

`/legal` is `root:root`, world-readable, and read-only for `agent`.

The [data model draft](data-model.md) proposes concrete inventory, source-cache, and source-bundle schemas, including authoritative JSON with a generated TSV summary. The interface changes remain a proposal until implementation adopts them.

## Component licenses

The repository-level licenses as reported by GitHub. Each one has to be confirmed against the actual file shipped with the pinned version.

| Component | License | Source of files | Notes |
| --- | --- | --- | --- |
| Go | BSD-3-Clause | image (`LICENSE`, `PATENTS`) | |
| Node.js | MIT + bundled deps | image if present, else vendored | Node's `LICENSE` includes the licenses of its bundled dependencies |
| Python | PSF-2.0 | image (`LICENSE.txt`) | |
| uv | MIT OR Apache-2.0 | vendored | Both license files |
| pnpm | MIT | npm package | |
| hadolint | **GPL-3.0** | vendored | Copyleft (see below) |
| shfmt | BSD-3-Clause | vendored | |
| jq | MIT (+ bundled oniguruma, BSD-2-Clause) | vendored (`COPYING`) | GitHub reports `NOASSERTION`; read `COPYING` |
| gomplate | MIT | vendored | |
| golangci-lint | **GPL-3.0** | vendored | Copyleft (see below) |
| betterleaks | MIT | vendored | |
| git-cliff | MIT OR Apache-2.0 | vendored | Both license files |
| GitHub CLI | MIT | release tarball | |
| oras | Apache-2.0 | image if present, else vendored | |
| Codex | Apache-2.0 | standalone package | Include `NOTICE` if shipped. The bundled `bwrap` (bubblewrap) is LGPL-2.0-or-later |
| Claude Code | **Proprietary** | Vendor terms and shipped notices | Preinstalled under the applicable Anthropic terms (see below) |

This table lists the primary non-apt tools. The generated inventory additionally covers all installed distro packages and bundled dependencies, with their individual licenses.

## Copyleft components

The image conveys hadolint and golangci-lint (GPL), the bubblewrap bundled with Codex (LGPL), and copyleft components supplied by Ubuntu and apt, including Bash and Git. Inventory each under its actual license version and provide the required **Corresponding Source**. Being unmodified or installed through apt does not remove redistribution obligations. See the [GNU FAQ on redistributing downloaded binaries](https://www.gnu.org/licenses/gpl-faq.en.html#UnchangedJustBinary).

For GPLv3 components, §6(d) permits source on another server but leaves availability obligations with the distributor. The project therefore **mirrors required source as OCI referrer artifacts** alongside each published image, with retrieval instructions in `/legal/SOURCE.md`. Source archives add registry storage and publishing work without increasing normal image downloads. Coverage and delivery must be reviewed under each component's license, including GPLv2 and LGPL; the GPLv3 mechanism alone is not a complete analysis of every component.

### What the source bundle contains

For statically linked tools, include required source for compiled-in libraries as well as the project's code. Preserve patches and build scripts needed for the distributed version:

| Component | Bundle contents | How the exact set is determined |
| --- | --- | --- |
| golangci-lint | Exact source revision, patches, build scripts, and required vendored dependencies | Upstream build provenance and module build list; checksums validate the selected dependency sources |
| hadolint | Exact source revision, build scripts, and required dependency sources | Upstream build metadata and `ThirdPartyNotices.txt`, checked against the distributed build |
| bubblewrap | Source for the bundled version, including downstream patches and required linked-library sources | Installed package provenance and upstream build recipe, with `bwrap --version` as a cross-check |
| Ubuntu base and apt packages with source obligations | Exact distro source package, including original archives, packaging files, and patches | Installed binary-to-source package mapping, source version, origin, and archive checksums for each architecture |

Each required source package becomes a versioned archive, and the archives are layers of a source artifact. Deduplicate shared source packages by checksum. Measure the complete bundle size during implementation; estimates covering only the three copied tools exclude distro packages and their patches.

Select sources from each platform's **built image inventory** and verify its recorded provenance. Preserve separate per-platform inventories because versions or patches can differ across architectures. Missing or ambiguous source provenance is an error to resolve, not a reason to substitute the latest upstream source.

### Reusing unchanged source archives

Source archives are reusable per component across image releases. A weekly or manual image build must not regenerate an archive merely because the image digest or build date changed.

- **Stable lookup key:** hash a canonical record containing the component name, binary SHA-256, platform, exact source/dependency/patch provenance, and the revision of that component's source-packaging recipe. Exclude image digests, workflow run IDs, dates, and unrelated component versions. Correcting source coverage or the packaging recipe must invalidate the key even if the binary is unchanged.
- **Persistent registry storage:** store the archive and its provenance/checksum record in an OCI artifact under an immutable `source-cache-<component>-<key>` tag in the image repository, mirrored to both registries. This survives eviction of GitHub Actions or BuildKit caches. It contains files, not a runnable environment.
- **Lookup before collection:** resolve the key and validate its recorded inputs and archive descriptors before downloading source or assembling a bundle. On a hit, reuse the existing blob digest and bytes. A missing artifact triggers collection for that component only. Authentication failures, lookup errors, or mismatched metadata fail explicitly rather than being treated as a cache miss.
- **Deterministic packaging:** sort archive entries, normalize timestamps and ownership, and use fixed compression settings. Keep run-specific metadata outside component archives, so rebuilding from identical inputs can reproduce the same blob digest.
- **New image attachments:** create a new small subject-specific manifest referencing existing archive blobs and the new image's inventory. A changed subject requires new attachment metadata, not new component source layers. Copy only blobs missing from the destination registry. Identical source archives from different platform keys can share the same content digest.
- **Retention:** keep cached archives and their lookup records while any retained publication needs them. Cleanup must follow shared references; a weekly build must never replace or delete another release's source archive.

For example, if hadolint and golangci-lint remain unchanged for ten weekly images, collect each source archive once and reuse its blob in all ten publications. Updated apt packages or a new agent release do not invalidate those two entries. These rules are design requirements; the repository does not yet implement the cache.

### Publishing

Both registries distribute the image publicly, so **both carry matching source artifacts** (see [maintenance.md](maintenance.md#workflow)). The publish workflow builds the image once. Testing runs alongside source attachment and promotion and does not control either operation.

1. **`build`** builds, pushes, and tags the `image` target on GHCR, recording the digest and each platform's inventory.
2. **`attach-ghcr`** runs immediately after `build`:
   1. Extract `/legal/manifest.tsv` from each platform image under the recorded digest. Resolve the [per-component source cache](#reusing-unchanged-source-archives) first. Run `scripts/build-source-bundles.sh` only for missing entries, in a separate environment containing the source-collection tools. Reuse validated archives by digest; never rebuild the runtime image to collect its source.
   2. Resolve the subjects: the index digest, plus every per-platform manifest in it. Skip the `unknown/unknown` entries, which are `bake.yml`'s attestation manifests, not images.
   3. Assemble and validate all required archives before running **one** `oras attach` per subject, using `--artifact-type application/vnd.frithuz.devcontainer.source.v1`. Attach each platform's sources and inventory to its manifest, and the union of both platforms' sources and inventories to the index. Shared blobs are deduplicated. Include archive checksums and provenance in the artifact.
   4. A re-run checks `oras discover` and validates existing artifact contents against the inventory before skipping a subject. An incomplete or mismatched artifact is a reported error; mere presence is insufficient.
3. **`promote`**, which depends on attachment but not tests, copies the same image to Quay with its referrers (`oras cp -r`). It confirms that every image subject has its source artifact through the native Referrers API, then applies the tags.

**Source gaps:**

- **Quay tags follow attachment.** Source is checked before consumer-facing tags are applied. The digest-only copy itself is public while the copy proceeds.
- **GHCR publishes before attachment.** The image is public from the initial push until `attach-ghcr` completes without its source referrer. A collection failure can extend that window. Retry attachment for the same digest and alert on unresolved failures; do not claim that removing a tag or passing tests addresses source availability. This delivery window needs coverage in the compliance review below. Public publishing is the chosen design; there is no private staging step.
- **Recovery:** test failures leave the image and source available in both registries. Attachment and copy failures are repaired using the original digest, as described in [synchronization and recovery](integrations/ghcr.md#synchronization-and-recovery).

**How each registry stores referrers:**

- **Quay** implements the OCI Referrers API natively. `GET /v2/<repo>/referrers/<digest>` returns an OCI image index, so artifacts are found through their `subject` link, with no tags involved. `--distribution-spec v1.1-referrers-api` makes `oras` use the API only, so a Quay-side problem fails loudly instead of silently creating fallback tags.
- **GHCR** has no Referrers API. Artifacts are listed in an index stored under the tag `sha256-<digest>`. GHCR rejects registry `DELETE`s with 405, so a subject's fallback index must never need rewriting. Hence one attach per subject, and re-runs that skip subjects that already have the artifact.

### Finding the source

`/legal/SOURCE.md` in the image gives the directions §6(d) requires "next to the object code". `oras` ships in the image, so this works from inside the container. The image can't know its own digest at build time, so the instructions start from the digest the user pulled. The same commands work for either registry: `oras discover` uses the Referrers API on Quay and the tag fallback on GHCR automatically.

```sh
digest=$(docker inspect --format '{{index .RepoDigests 0}}' <registry>/<repo>:<tag>)
oras discover --artifact-type application/vnd.frithuz.devcontainer.source.v1 "$digest"
oras pull "<registry>/<repo>@<referrer-digest>"
```

The same directions appear in the Quay repository description and the GHCR package description.

### Retention

Until a retention policy is adopted, keep all published images, source archives, cache records, and publication history in both registries with no automatic expiry or age/count limit. Durable records and their evidence belong in the registries; GitHub workflow artifacts are temporary transport, not the long-term record store. See the [registry record draft](data-model.md#publication-intent).

Source has to stay available as long as the image is, **in each registry**. Any cleanup of old images, such as pruning old `:YYYYMMDD` snapshots, must delete referrer artifacts **only together with their image, never before it**:

- **Quay:** source artifacts are untagged manifests linked to their image by `subject`. Cleanup must never delete untagged manifests that are the `subject`-linked referrers of an image that's still published.
- **GHCR:** source artifacts are reached through `sha256-<digest>` fallback tags. Cleanup must keep those tags, and the versions they point to, for as long as their subject image is kept.

Cleanup must account for shared platform manifests and source artifacts across retained releases. Determine reachability from all retained publications before deleting anything; never recursively delete a release's children merely because one index is removed. Test failures do not trigger deletion.

## Transitive dependencies

Most components are statically linked Go or Rust binaries. Those binaries embed their module dependencies, and many of those dependencies' licenses (MIT, BSD) require their notices to travel with the binary. The top-level `LICENSE` file doesn't cover them.

- Ship each component's license and the required notices for its bundled dependencies. Use upstream third-party notices when they cover the actual build; otherwise generate the missing notices from the exact dependency sources, for example with `go-licenses` or `cargo-about`.
- Required transitive notices are part of the initial packaging work. Adding or updating a dependency must update the notices and source inventory together.

## Claude Code

Claude Code stays **preinstalled**. Anthropic's [legal and compliance documentation](https://code.claude.com/docs/en/legal-and-compliance#can-customers-offer-claude-code-in-their-products) describes preinstallation under its Commercial Terms: keep the binary unmodified, preserve its built-in authentication methods, and have end users authenticate with their own credentials under the applicable terms. Do not resell or intermediate their usage. Follow the vendor's naming and branding conditions too.

Record the applicable terms and required shipped notices in `/legal/attribution/claude/`, using a proprietary license reference in the inventory rather than inventing an open-source license. Confirm the distribution setup meets those terms before the first public release. Runtime installation is not the planned delivery method.

## Enforcement

- **Project license:** `/legal/LICENSE` must match the repository's root `LICENSE`, and the inventory must distinguish the project's `CC0-1.0` files from third-party components. `/legal/README.md` and registry descriptions must explain that scope.
- **Build inventory:** every component must have a license identifier and notice locations in `manifest.tsv`. Non-apt components have `/legal/attribution/<component>/` entries; apt/base packages reference their preserved copyright files. Proprietary tools record applicable terms and provenance. Missing inventory or required notices fail packaging.
- **Source collection:** every component with source obligations maps to its exact source and patches. Validate archive checksums and complete coverage for both architectures before attachment. Collection errors fail attachment and trigger recovery; runtime test results are independent.
- **Adding a component** requires adding its attribution in the same PR.
- **Vendored files:** when Dependabot bumps a component with vendored license files, the license text rarely changes, but a change of license (e.g. a relicense) must be caught. A scheduled job compares each vendored file against the upstream file at the pinned version, and opens an issue on drift.

## Open questions

1. **Distribution compliance review.** Confirm the source delivery mechanism and availability during initial public pushes, coverage for the actual GPL/LGPL versions, complete transitive notices, and the Claude Code terms for this distribution before the first public release. The project's CC0 dedication does not resolve these questions.
