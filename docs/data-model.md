# Draft inventory and registry record schemas

This proposal defines the data exchanged by image inventory, source collection, and publication recovery. Durable records and their supporting files live in OCI artifacts in the image repositories, written to GHCR first and mirrored to Quay. Until a retention policy is adopted, retain everything indefinitely: no automatic expiry, pruning, or age/count limit.

The inventory describes the image as built. Runtime package installs and agent self-updates do not change the published inventory.

## Record formats

Use JSON for authoritative records. Arrays and nested objects represent multiple notices, dependencies, and source archives without inventing TSV escaping conventions. Keep `/legal/manifest.tsv` as a generated summary for people; collectors and recovery consume `/legal/inventory.json` instead. This is a proposed change to the TSV-based interfaces in [legal.md](legal.md).

| Record | Location | Purpose |
| --- | --- | --- |
| `inventory` | `/legal/inventory.json`, also a layer in source indexes | Exact installed components and source requirements, per platform |
| `source-image` | `/source/SOURCE.json` in a tagged `FROM scratch` source image | Complete source of one root program at one exact version, and the inputs that identify it; reused across releases |
| `source-index` | Layer of the source index referrer attached to an image index or platform manifest | Maps that image's inventories and components to the source images supplied for it |
| `publication` | Tagged OCI artifact, created before building | Immutable publication intent and recovery identity |
| `publication-event` | Separately tagged OCI artifact per operation attempt | Build results, attachment results, test results, and synchronization observations |

Each JSON record starts with `schemaVersion: 1` and `kind`, using one of the names above. All fields below are required unless marked optional. Empty arrays mean there are no entries; they must not mean collection failed. Unknown fields, duplicate JSON keys, unresolved references, and unsupported schema versions are errors. Breaking changes increment `schemaVersion` and the artifact type's version.

### Common types

| Type | Definition |
| --- | --- |
| `Digest` | `sha256:` followed by exactly 64 lowercase hexadecimal characters |
| `ID` | Nonempty ASCII identifier, `[a-z0-9][a-z0-9._-]*`, unique within its containing inventory |
| `Timestamp` | RFC 3339 UTC timestamp with `Z` |
| `Platform` | `{ "os": "linux", "architecture": "amd64" }` or the same with `"arm64"` |
| `Descriptor` | `{ "mediaType": string, "digest": Digest, "size": integer }`; size is nonnegative bytes |
| `Layer` | A `Descriptor` plus `name`, a unique relative artifact filename without `..` segments |
| `File` | `{ "path": string, "digest": Digest }`; normalized absolute image path, digest of file bytes |
| `Evidence` | A `Layer` plus `purpose` (nonempty string) |

Registry-local descriptors omit the registry hostname, so the same record bytes work in both registries. Explicit upstream references include their repository or download URL. Sizes and counters are integers from zero through `2^53 - 1`; numeric GitHub IDs are decimal strings.

Use an [OCI image manifest](https://github.com/opencontainers/image-spec/blob/main/manifest.md) with the specified `artifactType`, an empty OCI config, and a JSON layer named `record.json` plus the supporting layers. Only source indexes set the OCI `subject` field. Layer names become `org.opencontainers.image.title` annotations. Never put a record's own artifact digest in that record. An existing immutable tag is an idempotent success only when its descriptor and validated contents agree; otherwise report a conflict.

For content-derived keys, use SHA-256 over [RFC 8785 canonical JSON](https://www.rfc-editor.org/rfc/rfc8785). Before canonicalization, sort set-like arrays by their stable identifier, path, or digest as specified below, and reject duplicate entries. Preserve ordered arrays such as patch application order. Do not normalize version strings or source URLs. Artifact descriptors always hash the actual stored bytes, not a reserialized approximation.

## Inventory

| Field | Type and meaning |
| --- | --- |
| `schemaVersion`, `kind` | `1`, `"inventory"` |
| `platform` | `Platform` |
| `project` | `{ repository: string, revision: string }`; full source repository URL and full Git commit ID |
| `components` | `Component[]`, sorted by `id` |
| `sources` | `Source[]`, sorted by `id` |

An inventory cannot contain its own final image digest: embedding that digest would change the image. The source index and build event bind inventory bytes to the resulting image manifest. Do not put workflow timestamps or run IDs in the inventory.

### Component

| Field | Type and meaning |
| --- | --- |
| `id` | `ID`; distinguishes separate versions or copies of a component |
| `name`, `version` | Nonempty strings; installed version, including distro epoch/revision where applicable |
| `origin` | `Origin`, defined below |
| `payload` | `Layer`; points to an installed-file listing stored under `/legal/payloads/` and included in the inventory artifact layers |
| `embeddedIn` | Component IDs whose binaries contain this dependency; empty for separately installed components |
| `licenseExpression` | SPDX expression, including version-specific identifiers and `LicenseRef-*` for proprietary/custom terms |
| `notices` | `File[]`, sorted by path; required license/notice/terms files present in the image |
| `dependencies` | Component IDs, sorted; direct redistributed dependencies, including compiled-in libraries |
| `sourceIds` | Source IDs, sorted; exact source units associated with this component |
| `sourceRequired` | Boolean; explicitly determined for this component |
| `sourceDecision` | Nonempty explanation of source coverage or why no source distribution is required |

`payload.name` is relative to `/legal/`. Its JSON file is an array of entries sorted by absolute `path`. Each entry has `path`, `type` (`file` or `symlink`), and either `digest` for a regular file or `target` for a symlink. Store symlink targets verbatim. Exclude generated `/legal` metadata to avoid self-reference. Shared files may appear under more than one component. An embedded dependency can have an empty listing only with nonempty `embeddedIn`; a package with no installed files needs an explicit explanation in `sourceDecision`.

Every embedded dependency has its own license, notices, and source mapping. Its cache identity includes the payload descriptors of its containing binaries. A top-level tool license is not a substitute for dependency records.

### Origin

`origin` is a tagged union with `type` and exactly the fields for that type:

| `type` | Fields |
| --- | --- |
| `apt` | `binaryPackage`, `binaryVersion`, `packageArchitecture`, `repository`, `suite`, `sourcePackage`, `sourceVersion`, `packageDigest` |
| `image` | `repository`, `indexDigest`, `manifestDigest`, `paths` (source image paths copied), `evidence` (`File[]` containing upstream build/provenance records) |
| `npm` | `package`, `version`, `resolvedUrl`, `integrity` (original lockfile SRI), `lockfileDigest` |
| `release` | `url`, `digest`, `evidence` (`File[]`) |
| `installer` | `installerUrl`, `installerDigest`, `artifactUrl`, `artifactDigest`, `evidence` (`File[]`) |
| `project` | `repository`, `revision`, `paths` (repository-relative installed files) |
| `embedded` | `parentIds` (component IDs), `upstreamRepository`, `revision`, `evidence` (`File[]`) |

Digest-suffixed fields and `packageDigest` use `Digest`. Versions, revisions, URLs, and package names are strings; path lists are sorted string arrays. Preserve fetched installer/checksum/provenance evidence under `/legal/provenance/` and include those bytes with exported inventories. `embedded.parentIds` must equal `embeddedIn`.

For apt packages inherited from the base image, obtain the exact binary package checksum from authenticated repository metadata or retained upstream evidence. Failure to recover exact provenance is an error, not permission to record the current candidate version. Record a source image's platform manifest as well as its index; an index alone does not identify the copied architecture.

### Source

| Field | Type and meaning |
| --- | --- |
| `id` | `ID` |
| `name`, `version` | Exact upstream or distro source identity |
| `origin` | `{ type: "distro", repository, suite, package, version }` or `{ type: "upstream", repository, revision }` |
| `inputs` | `{ name, role, url, digest, size }[]`; `role` is `source`, `packaging`, `patch`, or `build-recipe`; sorted by name |
| `patchOrder` | Input names in application order; empty when patches are applied by the recorded distro packaging/build recipe |
| `dependencies` | Source IDs, sorted; source units needed in addition to this one |
| `recipe` | `{ repository, revision, path, digest }`; source-packaging recipe's full commit, path, and SHA-256 |

Input bytes must be independently verifiable. Git sources require an exact revision plus checksum-addressed input archives; a moving branch/tag is not sufficient. Distro inputs include the `.dsc`, original archives, and Debian/Ubuntu packaging archives as applicable. Preserve build recipes and patches inside the delivered archives, not just links to them.

Validation must check all component/source references, notice and payload hashes, source dependency closure, and the installed package database. Every `sourceRequired: true` component must have nonempty `sourceIds`. Unresolved source decisions fail collection. Multiple binary packages may map to one source unit. This inventory is the project's collection contract, not a replacement for the generated SBOM.

### TSV summary

Generate UTF-8 with LF endings and this exact header:

```text
component_id\tname\tversion\tarchitecture\tlicense_expression\tnotice_paths\tsource_ids\tsource_required
```

The displayed `\t` sequences represent actual tab separators. Encode each string cell as a compact JSON string, list cells as compact JSON arrays, and the boolean as JSON `true`/`false`. JSON escaping prevents embedded tabs/newlines from creating extra cells or records. Rows follow component ID order. The summary is never independently edited or used as a cache key.

## Source image

A source image holds the complete source of one root program at one exact version (see [legal.md](legal.md#source-images)). It's a regular OCI image built `FROM scratch`, so standard tools can pull and unpack it, with its record at `/source/SOURCE.json` and the source under `/source/<root>/`.

| Field | Type and meaning |
| --- | --- |
| `schemaVersion`, `kind` | `1`, `"source-image"` |
| `key` | `Digest`; hash of canonical `identity` |
| `identity` | `{ kind: "apt" \| "git" \| "bundle", root: string, version: string, ref: object, recipe: { repository, revision, path, digest } }` |
| `inputs` | `{ name, role, url, digest, size }[]`, sorted by name; `role` is `source`, `packaging`, `patch`, `build-recipe`, or `dependency` |
| `vendored` | `{ ecosystem: "go" \| "haskell", path: string, modules: { path, version, sum }[] }` or `null`; dependencies included in the tree, sorted by path |

`identity.ref` is, by kind:

| `kind` | `ref` |
| --- | --- |
| `apt` | `{ repository, suite, package, version, dscDigest }`; the source package as published in the archive's signed `Sources` index |
| `git` | `{ repository, commit, tag }`; `commit` is the full ID, `tag` is informational. `subpaths` (sorted) is set for sparse checkouts |
| `bundle` | `{ parts: ({ type: "git", repository, commit, subpaths } \| { type: "archive", url, digest })[] }`, sorted |

The key excludes image digests, publication IDs, dates, and the components that happen to use the source. Those belong in the source index, so the same source image serves every release. Recipe revisions are the last commits affecting the recipe and its helpers, not automatically each new repository HEAD; a corrected recipe changes the key even when the source didn't change.

The image is tagged `source-<root>-<version>-<key-hex[0:8]>`, with `<root>` and `<version>` sanitized to `[A-Za-z0-9_.-]` and the tag kept to 128 characters, truncating the readable part first. It carries the annotations `org.opencontainers.image.source`, `.version`, `.revision` (for `git`), and `vnd.frithuz.devcontainer.source.key` (the full key). The record and the archive layers are deterministic: sorted entries, fixed timestamps (`SOURCE_DATE_EPOCH`), numeric UID/GID zero, normalized modes with executable bits preserved, and fixed compression settings. Identical inputs reproduce the same digest. An existing tag is an idempotent success only when its digest and annotations agree; anything else is a conflict.

Verify every input against its recorded digest when building, and the vendored modules against the binary's embedded module list (`go version -m`) for Go roots.

## Source index

| Field | Type and meaning |
| --- | --- |
| `schemaVersion`, `kind` | `1`, `"source-index"` |
| `subject` | Image index or platform manifest `Descriptor` |
| `inventories` | `{ platform: Platform, image: Descriptor, layer: Layer }[]`, sorted by architecture |
| `components` | `{ inventoryDigest: Digest, componentId: ID, sourceImages: Descriptor[], decision: string }[]`, sorted by inventory digest then component ID; `decision` explains coverage, including dual-license elections and documented gaps |
| `sourceImages` | `{ image: Descriptor, tag: string, key: Digest }[]`, deduplicated and sorted by key |

The referrer is an OCI image index with `artifactType` `application/vnd.frithuz.devcontainer.source.v1` and `subject` set. Its `manifests` are the source images, by digest, each annotated with its `org.opencontainers.image.title` (root and version), plus one artifact manifest carrying this record as `record.json` and the inventories as layers. Because the source images are in the same repository and part of the referrer's graph, `oras cp -r` copies them with the image.

A platform source index covers exactly its inventory. The index-level source index covers every supported platform in the image index, excluding attestation manifests. For every component that owes source, validate that each referenced source image exists, matches its key, and covers the component; unresolved components fail the `sources` job.

Create one source index per subject as specified in [legal.md](legal.md#publishing). Validate an existing one before skipping it on retry. Conflicting contents fail explicitly. Publication events are separately tagged artifacts and do not add further referrers to the image's GHCR fallback index.

## Publication intent

| Field | Type and meaning |
| --- | --- |
| `schemaVersion`, `kind` | `1`, `"publication"` |
| `id` | `gh-<repository-id>-<original-run-id>` |
| `repository` | Source repository URL |
| `revision` | Full source Git commit ID |
| `workflow` | Repository-relative workflow path |
| `run` | `{ id: string, createdAt: Timestamp, trigger: "push" \| "schedule" \| "manual" }` |
| `registries` | `{ primary: string, mirror: string }`; complete GHCR and Quay repository names, without tags |
| `tags` | `{ name: string, policy: "immutable" \| "mutable" }[]`, sorted by name |
| `recoveryImageTag` | `build-<publication-id>`; permanent image tag for this publication |
| `retention` | `{ "mode": "keep-all" }` |

Store as artifact type `application/vnd.frithuz.devcontainer.publication.v1` at immutable tag `publication-<id>`. Write the intent to GHCR before invoking the build. Use its original run creation date for scheduled snapshot tags. A new manual build has its own ID; a manual repair targets the original intent and does not create a new publication or date tag.

The build also pushes `recoveryImageTag`. This binds a publication to its image even if the workflow dies after pushing but before recording its output. On retry, inspect that tag and any planned immutable snapshot tags in both registries before building. Existing references must agree; errors are not absence. A complete existing image resumes recovery. Partial upload/signing failures require inspection before permitting another build. Once assigned, the recovery tag must never move to a different digest.

A publication intent contains no image digest because the build has not happened yet. Its immutable build-success event supplies that binding. Mirror the intent, recovery tag, and events explicitly; copying only the image's referrers will not copy these records.

Example intent (illustrative repository, run, and revision):

```json
{
  "schemaVersion": 1,
  "kind": "publication",
  "id": "gh-123456-987654",
  "repository": "https://github.com/example/devcontainer",
  "revision": "1111111111111111111111111111111111111111",
  "workflow": ".github/workflows/publish.yml",
  "run": {
    "id": "987654",
    "createdAt": "2026-10-25T04:00:00Z",
    "trigger": "schedule"
  },
  "registries": {
    "primary": "ghcr.io/example/devcontainer",
    "mirror": "quay.io/frithuz/devcontainer"
  },
  "tags": [
    { "name": "20261025", "policy": "immutable" },
    { "name": "latest", "policy": "mutable" }
  ],
  "recoveryImageTag": "build-gh-123456-987654",
  "retention": { "mode": "keep-all" }
}
```

## Publication events

| Field | Type and meaning |
| --- | --- |
| `schemaVersion`, `kind` | `1`, `"publication-event"` |
| `publication` | Intent artifact `Descriptor` |
| `publicationId` | Intent's `id` |
| `execution` | `{ runId: string, runAttempt: integer, operation: string, sequence: integer }`; attempts/sequences start at 1 |
| `observedAt` | `Timestamp` |
| `stage` | `build`, `source`, `verify`, or `sync` |
| `status` | `succeeded`, `failed`, or `cancelled` |
| `image` | Image index `Descriptor`, or `null` only before the build's digest is known |
| `details` | Stage-specific object below |
| `evidence` | `Evidence[]`; reports and sanitized logs stored as layers in this artifact |
| `error` | `null` on success; otherwise `{ code: string, message: string }` |

`operation` identifies a job/matrix operation (for example `verify-linux-arm64-agent`). Each operation owns its own monotonically increasing sequence within an execution attempt. Retries reuse the same event bytes or create a new sequence, never overwrite an event. Parallel operations have distinct names and cannot contend for the same tag.

| Stage | `details` |
| --- | --- |
| `build` | `{ platforms: { platform: Platform, image: Descriptor, inventory: Layer }[], supportingFiles: { inventoryDigest: Digest, path: string, layer: Layer }[] }`; a success lists both platform manifests and includes inventory/supporting files as layers |
| `source` | `{ attachments: { subject: Descriptor, artifact: Descriptor }[], sourceImages: { image: Descriptor, tag: string, built: boolean }[] }`; a success covers the index and both platform images; `built` is `false` for reused source images |
| `verify` | `{ platform: Platform, user: "agent" \| "root", suite: string, report: Layer }`; one event per suite/platform/user; report is also an evidence layer |
| `sync` | `{ destination: string, checkedArtifacts: Descriptor[], tags: { name: string, digest: Digest }[] }`; describes verified remote state, including source images, source indexes, and record artifacts copied during this operation |

Failed/cancelled events may contain partial or empty result arrays. A failed verification still includes its report; a cancellation before report creation uses `details: null`. No stage failure is interpreted as success, and missing events mean unknown, not passing. Once an image digest is known, all events must agree with the immutable build binding.

Use artifact type `application/vnd.frithuz.devcontainer.publication-event.v1`. Compute the event key as SHA-256 of canonical `{ publicationId, execution }` and use immutable tag `event-<key-hex>`. Add OCI annotations for publication ID, stage, operation, and observation time. Initial discovery lists the reserved `event-*` tags and filters records; indexes may be added later as conveniences, never as the only source of history.

The event artifact has no OCI `subject`. Its JSON descriptor links it to the intent, avoiding repeated writes to GHCR's image referrers index. Store reports and sanitized diagnostic logs in artifact layers; GitHub job URLs can supplement them but are not durable evidence. Never copy credentials or unfiltered environment dumps into these public records.

## Mirroring and recovery

1. Read the immutable publication intent and resolve its recovery image tag. Validate the index and platform descriptors; recover a missing build event from the published image and its embedded inventories after confirming revision/platform identity.
2. Read events, but verify current registry state before acting. Build only missing source images and attach only missing source indexes, then copy missing images, source images, records, and evidence by digest. Registry copying must enumerate the JSON-linked artifacts explicitly.
3. Check every destination tag before assigning it. Immutable conflicts fail. Mutable tags are ordered by original publication creation time, with original run ID as a numeric tie-breaker, separately for each tag. Recovery must not move them behind a newer publication that has already assigned that tag.
4. Write fresh observation events for completed recovery work. Existing events remain historical facts. A newer test result does not erase an earlier failure, and test results never gate synchronization.
5. Mirror events produced after image promotion as a separate repairable operation. A sync event enumerates the artifacts it actually checked and cannot include itself. Copy that event after writing it and validate its digest in both registries without requiring another self-referential completion record.

Publication and repair workflows share the existing concurrency group for tag mutations. Record publication/mirroring failures are reported separately and must be retried. While a registry is unavailable, workflow outputs/artifacts can hold temporary pending records; they are not the authoritative long-term store. A crashed job can leave its test outcome unknown until the suite is rerun; recovering the image is not evidence that tests passed.

## Retention and validation

There is currently **no retention limit**. Keep image recovery tags, snapshot images, publication intents, all events and reports, source images (`source-*` tags), source indexes, and GHCR fallback tags in both registries. Do not configure automated cleanup. Tagged roots protect the records from ordinary untagged-artifact cleanup; source-referrer persistence still requires the checks described in [Quay setup](integrations/quayio.md#5-verify).

Any future cleanup policy must trace actual OCI layers and all JSON descriptor references before deleting records or shared artifacts. Unlimited project retention is a policy, not a guarantee about registry quotas or service availability.

Before implementation, translate these field definitions into JSON Schema and add semantic validation for cross-record references, source closure, hashes, artifact layers, immutable tags, and platform coverage. JSON Schema alone cannot prove those relationships. Include examples for distro packages, embedded libraries, proprietary agents, partial publication, and retries. These are schema drafts; no collector or publisher is implemented here.
