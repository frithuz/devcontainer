# Inventory and registry records (draft)

> Draft: only source images and source indexes are implemented (`scripts/build-source-image.sh`, `scripts/source-indexes.sh`). The other records are a proposal. Turn them into JSON Schemas when implementing, plus semantic validation for what a schema can't express: cross-record references, source closure, hashes, and platform coverage.

These records connect what's in an image, where its source is, and what happened during publication. Durable records live as OCI artifacts in the image's own repositories, written to GHCR first and mirrored to Quay, so the evidence travels with the image instead of living in GitHub workflow artifacts. Workflow artifacts can carry pending records temporarily, but they aren't the long-term store.

## Record formats

| Record | Where | Purpose |
| --- | --- | --- |
| `inventory` | `/legal/inventory.json`, and a layer of the source index's record | Exact installed components and source requirements, per platform |
| `source-image` | `/source/SOURCE.json` in each source image | One root program's complete source at one exact version |
| `source-index` | Referrer attached to an image index or platform manifest | Maps that image's components to the source images supplied for it |
| `publication` | Tagged artifact, written before building | Immutable publication intent and recovery identity |
| `publication-event` | Tagged artifact per operation attempt | Build, source, test, and sync results |

Design rules:

- **JSON is authoritative.** `manifest.tsv` becomes a generated summary for people, and collectors read `inventory.json`. Arrays and nested objects represent multiple notices, dependencies, and archives without inventing TSV escaping.
- **Strict validation.** Unknown fields, duplicate keys, unresolved references, and unknown schema versions are errors. An empty array means "none", never "collection failed".
- **Records never contain their own digest**, and an inventory never contains its image's digest, because embedding either would change it. The binding goes in the other direction: source indexes and build events point at the image.
- **Registry-neutral bytes.** Descriptors omit the registry hostname, so the same record is valid in both registries.
- **Content keys** are SHA-256 over [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785) canonical JSON, with set-like arrays sorted first. Version strings and URLs are never normalized.
- **Immutable tags.** Re-pushing an existing tag succeeds only when its contents match. Anything else is a conflict.

## Inventory

One per platform: every component, with its exact origin (apt package and checksum, image digest, release URL, installer and artifact digests, and so on), license expression, notices, dependencies, embedded libraries, and the source units it needs. Each component records an explicit `sourceRequired` decision and its reason. An unresolved decision fails collection. Embedded dependencies are components of their own, because a tool's top-level license doesn't cover them.

The inventory describes the image as built. Runtime package installs and agent self-updates don't change it. Workflow timestamps and run IDs stay out, so a rebuild with the same inputs produces the same inventory. Inherited base-image packages need exact provenance from authenticated repository metadata. Failing to recover it is an error, not permission to record the current candidate version.

## Source image

The key is the hash of the source's identity: its kind (`apt`, `git`, or `bundle`), root, exact version, exact reference (`.dsc` digest, full commit, or archive digests), and recipe revision. It excludes image digests, dates, and which components use the source, which is what lets one source image serve every release. A corrected recipe changes the key even when the source didn't change.

Tags are `source-<root>-<version>-<key[0:8]>`, sanitized to the tag character set and at most 128 characters. Consumers' Dependabot ignores them, because it only proposes tags with the same format as the pinned one. Layers are deterministic (sorted entries, fixed timestamps, numeric owner zero), so identical inputs reproduce the same digest. `SOURCE.json` records every input with its digest and, for Go roots, the vendored modules with their `go.sum` hashes.

## Source index

An OCI image index of artifact type `application/vnd.frithuz.devcontainer.source.v1`, with `subject` set to the image index or a platform manifest. The image index's source index covers every platform, and a platform manifest's covers only its architecture. Because the source images are part of the referrer's graph and in the same repository, `oras cp -r` copies them along with the image. `scripts/source-indexes.sh` builds them from `plan.tsv` with no timestamps, so a retry produces the same digest. Its `manifests`, in order:

1. **The record:** a manifest of artifact type `application/vnd.frithuz.devcontainer.source.record.v1`, titled `source record`, with an empty config and one `application/vnd.frithuz.devcontainer.source.record.v1+json` layer. The layer maps the subject's components (`<arch>:<component>`, as in `plan.tsv`) to their source images, gaps, and elections:

   ```json
   {
     "platform": "linux/arm64",
     "sources": [{"tag": "source-…", "key": "sha256:…", "kind": "apt", "root": "bash", "version": "5.3-2ubuntu1", "digest": "sha256:…", "components": ["arm64:deb:bash"]}],
     "gaps": [{"root": "pebble", "reason": "…", "components": ["arm64:pebble"]}],
     "elections": [{"root": "…", "license": "…", "components": ["…"]}]
   }
   ```

   `platform` is `null` in the image index's record. The inventory, once it exists, is a second layer.
2. **The source images**, sorted by tag, each annotated with `org.opencontainers.image.title` (`<root> <version>`) and `vnd.frithuz.devcontainer.source.key`.

Exactly one per subject: GHCR can't rewrite a referrer fallback index ([legal.md](legal.md#publishing)). For the same reason, publication events don't attach to the image as referrers.

## Publication intent

Written to GHCR **before** the build, with an ID derived from the original workflow run. It names the revision, the planned tags, and a permanent recovery tag (`build-<id>`) that the build also pushes. That binds a publication to its image even if the workflow dies between pushing and recording the push. The intent holds no image digest, because the build hasn't happened yet. The build's success event supplies it. Scheduled snapshot dates come from the original run's creation time, so a manual repair resumes the original publication instead of creating a new date tag.

## Publication events

One immutable, separately tagged artifact per operation attempt (`event-<key>`), keyed by publication ID and execution. A retry either reuses identical bytes or adds a new sequence number, and never overwrites an event. Parallel operations have distinct names, so they can't contend for a tag. Events link to the intent through their JSON, not an OCI `subject`, to avoid repeated writes to GHCR's referrers index. They store reports and sanitized logs as layers, never credentials or raw environment dumps.

A missing event means unknown, not passing. A newer test result doesn't erase an earlier failure, and test results never gate synchronization.

## Mirroring and recovery

Recovery starts from the intent and its recovery tag, then checks current registry state before acting. Events say what was attempted, and the registries say what's true. It builds or copies only what's missing, by digest. Records that aren't image referrers are copied explicitly, because `oras cp -r` won't find them.

Immutable tag conflicts fail. Mutable tags are ordered by original publication time, so recovering an older run never moves `:latest` or `:main` behind a newer publication. A sync event can't list itself, so it's mirrored and validated as a separate step. Recovering an image is not evidence that its tests passed.

## Retention

No limit: keep recovery tags, snapshots, intents, events, source images, source indexes, and GHCR fallback tags in both registries, with no automated cleanup. Any future policy has to trace every OCI and JSON reference before deleting, and has to follow the [legal retention rules](legal.md#retention). Unlimited retention is a policy, not a guarantee about registry quotas.
