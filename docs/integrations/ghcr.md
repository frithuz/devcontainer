# GHCR (mirror)

`ghcr.io/<owner>/devcontainer` is the **public build destination and mirror** of the image. `docker/github-builder`'s `bake.yml` builds and pushes here first, and the `promote` job copies that digest to Quay while tests run independently. GHCR and Quay carry the same images, tags, signatures, and source artifacts after synchronization completes. There is no private staging package.

The mirror exists for two reasons:

- **`bake.yml` can push to it without a stored secret.** It logs in with GitHub's automatic `GITHUB_TOKEN`. Quay would need a static robot token, because `bake.yml` has no Quay identity type.
- **Fast, free pulls for GitHub Actions.** Runners pull from GHCR inside GitHub's network, which makes it the natural registry for CI consumers ([usage.md](../usage.md#which-registry)).

## How the two registries differ

| | Quay (default distribution registry) | GHCR (build destination and mirror) |
| --- | --- | --- |
| Gets new tags | After source attachment and copying, independently of tests | Immediately, from `bake.yml` |
| Referrers (signatures, source) | Native OCI Referrers API | Referrers tag fallback (`sha256-<digest>` tags) |
| How artifacts show in the UI | Linked to their image | As extra `sha256-*` tags and untagged versions |
| On a failed test | Receives and keeps the image | Keeps the image |
| Deletion | Registry API / Quay UI | GitHub Packages REST API only (registry `DELETE` returns 405) |

Because `bake.yml` tags GHCR directly, a new image is public before tests finish and before source attachment. `attach-ghcr` runs immediately after the push, and `promote` follows it without waiting for `verify`. A failing test is reported without reverting tags or deleting the image. Attachment and copy failures are retried and alerted separately; see [recovery](#synchronization-and-recovery).

## Setup (once)

1. **First push creates the package.** The `build` job pushes with `GITHUB_TOKEN`, which creates `devcontainer` under the repository owner, linked to this repository. Public visibility is fine. If GitHub creates it as private, change it to **Public** in **Package settings** (that change is one-way).
2. **Grant the repository Write.** In **Package settings → Manage Actions access**, give this repository write access for publishing and attaching artifacts. Retention deletion, when implemented, requires the **Admin** role. Add no other repositories.
3. **Restrict people.** Under **Manage access**, grant no users or teams beyond the owner's admins. All writes come from this repository's workflow.

## Workflow permissions

| Job | `permissions` | Login |
| --- | --- | --- |
| `build` (`bake.yml`) | `contents: read`, `packages: write`, `id-token: write` (bake.yml signing and cache) | `registry-auths: - registry: ghcr.io / username: ${{ github.actor }} / password: ${{ secrets.GITHUB_TOKEN }}` |
| `attach-ghcr` | `contents: read`, `packages: write` | `oras login ghcr.io` with `GITHUB_TOKEN` |
| `verify` | `contents: read`, `packages: read` | none needed (public), or `container.credentials` with `GITHUB_TOKEN` |
| `promote` | `contents: read`, `packages: read`, `id-token: write` (Quay federation) | `oras login ghcr.io` with `GITHUB_TOKEN` |

`secrets.GITHUB_TOKEN` is created by GitHub for each run and expires when the run ends. It isn't a stored secret.

## Source artifacts on GHCR

GHCR is a public distribution point, so it needs the copyleft source just like Quay ([legal.md](../legal.md#publishing)). `attach-ghcr` attaches the bundles to the GHCR index and per-platform manifests right after `build`. GHCR has no Referrers API, so `oras` writes them through the referrers tag fallback:

- **One attach per subject.** Adding a second artifact to a subject rewrites its `sha256-<digest>` index, and the client then tries to `DELETE` the old one, which GHCR rejects with 405. All bundles go into **one** artifact per subject in a single `oras attach`. `bake.yml`'s signatures attach to the *attestation* manifests, which are different subjects.
- **The fallback tags are real tags.** Any GHCR retention or cleanup must keep `sha256-*` tags for as long as their subject image is kept.

`promote` then copies the image to Quay **with its referrers** (`oras cp -r`), so Quay receives the same signatures and source artifact, stored natively.

## Synchronization and recovery

Record each publication's digest, tags, and source inventories so recovery can resume the same publication without a rebuild. The two registries cannot update atomically; synchronization is complete when tags resolve to the same digests and required artifacts are discoverable in both.

Store durable records, test reports, and recovery evidence in registry artifacts, mirrored to both registries. GitHub workflow artifacts may transport pending records, but are not their long-term home. The [data model draft](../data-model.md) specifies immutable publication intents and operation events, with explicit copying of records that are not image referrers.

- **Test failure:** preserve the result, logs, and affected digest, and open or update an issue. Continue synchronization and keep the image in both registries.
- **Attachment or copy failure:** retry with bounded backoff, then mark publication incomplete and alert. Resume missing attachments or copies using the recorded digest. Do not delete images as recovery.
- **Partial tagging:** retry missing tags. An existing date tag must match the recorded digest; a different digest is a conflict to report, never an overwrite.
- **Older run recovery:** use the same concurrency group as publishing. Restore missing snapshots and artifacts, but never move a mutable tag back over a newer publication. Reconcile mutable tags to the latest recorded publication.
- **Partial build push:** if the reusable workflow fails after uploading content, inspect the registry before retrying. Preserve any assigned snapshot digest and recover its publication record rather than blindly replacing its tag.

The workflow summary reports test status and synchronization status separately. Failure in either is visible; test status does not control promotion.

## Retention

GHCR follows **the same retention as Quay**. Currently retain all snapshots, source/cache artifacts, publication records, and evidence without automatic expiry or age/count limits. A future deletion policy is still to be decided ([maintenance.md](../maintenance.md#tags-and-schedule)); under such a policy, a snapshot must never be removed from GHCR before Quay, and its required `sha256-*` referrer tags must remain while the image is retained. Source stays available as long as its image is ([legal.md](../legal.md#retention)).

Before deleting manifests, calculate reachability from every retained index, tag, and publication awaiting synchronization. A platform manifest can be shared by multiple releases. Keep shared manifests, their source artifacts, and signatures until no retained publication needs them. Test failure is never a retention criterion.

## Known risk

`bake.yml` signs on GHCR through the referrers tag fallback. Each attestation manifest is signed once, so no fallback index should need replacing. Confirm on the first run that `build`'s signing step succeeds, that `attach-ghcr` succeeds, and that `promote` copies both kinds of referrers to Quay.
