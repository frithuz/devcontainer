# Legal notices and attribution

The image redistributes binaries from many upstream projects, so it carries their license and notice files with it. Everything lives under one root directory:

```text
/legal/
├── README.md                    # What this directory is and how it's laid out
├── SOURCE.md                    # Where to get Corresponding Source for copyleft components (OCI referrers)
├── manifest.tsv                 # Generated at build: component, version, SPDX license, source URL
└── attribution/
    └── <component>/             # One directory per component (go, node, python, uv, hadolint, ...)
        ├── LICENSE*             # Verbatim upstream license file(s)
        ├── NOTICE*              # Verbatim upstream NOTICE / third-party notices, when the project ships them
        └── SOURCE               # Upstream repository, license path, SPDX ID, and source location for copyleft components
```

**Scope:** `/legal` covers what the image copies in or installs from outside the package manager, meaning source images, npm, release tarballs, and standalone installers. Packages installed with apt (the Ubuntu base, git, sudo-rs, locales, Docker Engine, Python's runtime libraries) already carry their copyright files at `/usr/share/doc/<pkg>/copyright`, where they're expected. `/legal` doesn't duplicate them, and they must never be excluded or deleted, even when other docs are trimmed.

The license for this repository's own files is a separate question (see [Open questions](#open-questions)).

## How files get there

From most to least preferred:

1. **From the source image.** If the pinned upstream image contains the project's license files, `COPY --from=<stage>` them into `/legal/attribution/<component>/`. These match the copied binary exactly. Examples: `/usr/local/go/LICENSE` and `PATENTS`, and Python's `LICENSE.txt`.
2. **From the install artifact.** For npm packages (`/opt/tools/node_modules/*/LICENSE*`) and release tarballs, such as `gh` and the Codex standalone package, collect license files from what was actually installed.
3. **Vendored in this repository.** For images that ship only a binary, such as distroless or `scratch` images like hadolint, shfmt, jq, gomplate, golangci-lint, betterleaks, git-cliff, and uv, commit the upstream license file under `legal/attribution/<component>/` in this repo. `COPY legal/ /legal/` brings them in. Each vendored file records in `SOURCE` the upstream path it was taken from.
`scripts/collect-legal.sh` gathers the install-artifact files (step 2) and writes `/legal/manifest.tsv`, a row per component with its version (from `--version`), SPDX license ID, and upstream URL. It runs as root after the agent installers, so the agent CLIs are covered.

`/legal` is `root:root`, world-readable, and read-only for `agent`.

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
| Claude Code | **Proprietary** | n/a | No open-source license (see below) |

## Copyleft components

hadolint and golangci-lint (GPL-3.0), and the bubblewrap bundled with Codex (LGPL), are distributed as binaries in a published image. Publishing the image conveys them, and GPL-3.0 §6 requires conveying their **Corresponding Source** with them. Being unmodified doesn't exempt them. For each one, `SOURCE` records the upstream repository and the exact tag of the shipped version.

Pointing to upstream alone isn't enough. §6(d) lets the source live on a third-party server, but *"you remain obligated to ensure that it is available for as long as needed"*. The project therefore **mirrors the source itself, as OCI referrer artifacts** attached to every published image in the same registry. That keeps the source "through the same place" as the image (§6(d)), adds nothing to the image's size, and works for scheduled builds that have no release cycle.

### What the source bundle contains

The binaries are statically linked, so Corresponding Source covers the libraries compiled into them, not just each project's repository:

| Component | Bundle contents | How the exact set is determined |
| --- | --- | --- |
| golangci-lint | Tag archive plus `go mod vendor` output | `go.sum` at the tag pins every module |
| hadolint | Tag archive plus the Hackage source tarball of every dependency | The repo has no freeze file, so the versions come from upstream's `ThirdPartyNotices.txt` at the tag |
| bubblewrap | Tag archive for the version bundled in Codex | `bwrap --version` from the installed Codex package |

Each component becomes one `<component>-<version>-source.tar.xz`, and all of them are layers of a single artifact. At current versions the set is about **17 MB** (golangci-lint 10 MB, hadolint 6.8 MB, bubblewrap 0.1 MB).

Versions are read from the **built image** (`/legal/manifest.tsv` and `--version`), never from the Dockerfile, so the bundle always matches what was shipped.

### Publishing

Both registries distribute the image publicly, so **both carry the source artifacts** (see [maintenance.md](maintenance.md#workflow)). `docker/github-builder`'s `bake.yml` pushes and tags on GHCR, and our `promote` job copies the image, with its referrers, to Quay, the source of truth.

1. **`preflight`** builds the `preflight` target. Inside the build, `scripts/build-source-bundles.sh` reads the image's `/legal/manifest.tsv` and builds every bundle. Fetching uses the network (GitHub, the Go module proxy, Hackage), but nothing fetched is executed. The bundles and the `manifest.tsv` they came from are uploaded as a GitHub artifact. **If any bundle fails, nothing is pushed anywhere.**
2. **`build`** builds, pushes, and tags the `image` target on GHCR with the same cache scope, so it normally reuses the exact layers `preflight` built.
3. **`attach-ghcr`** runs immediately after `build`:
   1. Read `/legal/manifest.tsv` from the pushed image by digest, and compare it with the preflight artifact's copy. A cache miss can re-run the unpinned steps, for example installing a newer Codex with a different bundled `bwrap`. If the versions differ, rebuild the affected bundles from the pushed image's versions with the same script.
   2. Resolve the subjects: the index digest, plus every per-platform manifest in it. Skip the `unknown/unknown` entries, which are `bake.yml`'s attestation manifests, not images.
   3. Run **one** `oras attach` per subject, using `--artifact-type application/vnd.frithuz.devcontainer.source.v1`, one layer per component, and `org.opencontainers.image.title` and version annotations. On GHCR this goes through the referrers tag fallback. Attaching to each platform manifest means a platform image copied out on its own still carries its source link. The blobs are deduplicated, so the extra attachments cost nothing.
   4. A re-run first checks `oras discover` and skips subjects that already have the source artifact, so a subject's fallback index is never rewritten.
4. **`promote`** copies the image to Quay with its referrers (`oras cp -r`), so the same source artifact lands on Quay as a native referrer. It confirms with `oras discover --distribution-spec v1.1-referrers-api` that every subject has it, and **only then** applies the Quay tags.

**Source gaps:**

- **Quay has none.** An image is only tagged there after its source is confirmed attached.
- **GHCR has a short one.** `bake.yml` tags GHCR as part of its push, before any job of ours can run. From then until `attach-ghcr` finishes, normally a few minutes, the new image is public on GHCR without its source. That's the accepted cost of letting `bake.yml` tag GHCR directly. If `attach-ghcr` fails, `rollback-ghcr` points GHCR's tags back at the Quay digests, which have source, or deletes the new version ([integrations/ghcr.md](integrations/ghcr.md#rollback)).

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

Source has to stay available as long as the image is, **in each registry**. Any cleanup of old images, such as pruning old `:YYYYMMDD` snapshots, must delete referrer artifacts **only together with their image, never before it**:

- **Quay:** source artifacts are untagged manifests linked to their image by `subject`. Cleanup must never delete untagged manifests that are the `subject`-linked referrers of an image that's still published.
- **GHCR:** source artifacts are reached through `sha256-<digest>` fallback tags. Cleanup must keep those tags, and the versions they point to, for as long as their subject image is kept.

## Transitive dependencies

Most components are statically linked Go or Rust binaries. Those binaries embed their module dependencies, and many of those dependencies' licenses (MIT, BSD) require their notices to travel with the binary. The top-level `LICENSE` file doesn't cover them.

- **Phase 1** (this design) ships each component's own license, plus any third-party notice file the upstream publishes.
- **Known gap:** full transitive notices for Go and Rust binaries. Options to evaluate are generating them from source at the pinned tag (e.g. `go-licenses` for Go, `cargo-about` for Rust), or using notices files that upstreams publish in their releases.

## Claude Code

Claude Code isn't open source. It's provided under Anthropic's terms, not under a license that grants redistribution. **Publishing a built image to a public registry redistributes the Claude Code binary**, and that needs to be checked against Anthropic's terms before the first public release. If redistribution isn't permitted, the alternative is to install Claude Code at container start rather than at build time.

## Enforcement

- **CI:** every component in the [tooling inventory](tooling.md) that isn't installed with apt must have a `/legal/attribution/<component>/` directory with at least one license file and a `SOURCE` file. Every row in `manifest.tsv` needs a non-empty license. Missing entries fail the build.
- **Adding a component** requires adding its attribution in the same PR.
- **Vendored files:** when Dependabot bumps a component with vendored license files, the license text rarely changes, but a change of license (e.g. a relicense) must be caught. A scheduled job compares each vendored file against the upstream file at the pinned version, and opens an issue on drift.

## Open questions

1. **This repository's own license.** Which license covers this repo's Dockerfile, scripts, and docs? It would also be shipped as `/legal/LICENSE` and declared in the `org.opencontainers.image.licenses` label.
2. **Copyleft compliance review.** The referrer-artifact approach follows GPL-3.0 §6(d) as read in this document. Have it confirmed before relying on it for commercial use.
3. **Claude Code redistribution** in a published image (see above).
