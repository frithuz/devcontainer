# /legal

License notices, attribution, and source information for the software in this image.

**Project files: CC0-1.0. Bundled third-party software: respective upstream licenses and terms; see /legal.**

- `LICENSE` is the CC0-1.0 dedication for this project's own files: its Dockerfile, scripts, image
  configuration, and documentation. It is not a license for any third-party component.
- `manifest.tsv` lists every component in the image: the project itself, the Ubuntu base and apt
  packages, copied tools, release downloads, standalone installers, and bundled dependencies.
  Columns: component, version, architecture, license, notice locations, and source provenance.
- `attribution/<component>/` holds the upstream license and notice files for components not
  installed with apt, taken from the source image or fetched from upstream at the installed
  version during the build. Each directory's `SOURCE` file records where its files came from,
  with their checksums.
- Packages installed with apt keep their notices at `/usr/share/doc/<package>/copyright`, which
  `manifest.tsv` references instead of copying.
- `sbom/devcontainer.cdx.json` is a CycloneDX list of the components SBOM scanners can't
  identify from the files alone (standalone binaries without package metadata, and the
  libraries bundled with Codex), with versions, licenses, and checksums. The image's SBOM
  attestation picks it up.
- `go/pkg/mod/<module>@<version>/` holds the license files of every Go module compiled into
  the image's Go binaries, taken from the module source through the Go proxy.
- `provenance/` keeps build-time evidence, such as the exact `.deb` URLs and checksums of the
  installed apt packages.
- `SOURCE.md` explains how to get Corresponding Source for copyleft components.

Claude Code is proprietary software preinstalled under Anthropic's terms; see
`attribution/claude/LICENSE.md`, Anthropic's notice from the release of the installed version.
