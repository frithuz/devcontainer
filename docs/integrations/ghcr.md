# GHCR (mirror)

`ghcr.io/<owner>/devcontainer` is the **public build destination and mirror** of the image. `bake.yml` pushes there first, and `promote` copies that digest to Quay. After synchronization, both registries carry the same images, tags, and signatures. The sandbox kits follow the same path through their own packages, `ghcr.io/<owner>/claude-kit` and `ghcr.io/<owner>/codex-kit` ([maintenance.md](../maintenance.md#publishing-the-kits)). There's no private staging package. For now only runs that tag `latest` (pushes to `main`, and manual runs that ask for it) are promoted, so GHCR also carries the scheduled and other manual builds that Quay doesn't.

The mirror exists for two reasons:

- **`bake.yml` can push to it without a stored secret**, using GitHub's automatic `GITHUB_TOKEN`. Pushing to Quay would need a static robot token, because `bake.yml` has no Quay identity type.
- **Fast, free pulls for GitHub Actions** inside GitHub's network ([usage.md](../usage.md#which-registry)).

## How GHCR differs from Quay

- **No Referrers API.** Signatures live in fallback indexes under `sha256-<digest>` tags, which show up in the package's version list. These are real tags: any cleanup has to keep them as long as their subject image.
- **No registry `DELETE`** (it returns 405). Deletion goes through the GitHub Packages REST API only. Adding a second referrer to a subject rewrites its fallback index, and the client then tries to delete the old one, which fails, so a subject can take only one referrer. `bake.yml`'s signatures attach to the attestation manifests, which are different subjects.
- **Tagged earlier.** GHCR gets public tags right after `build`. Quay gets them after `promote`.
- **Descriptions come from the index.** For a multi-platform image, GHCR shows the image index's `org.opencontainers.image.description` annotation, not the config label. `publish.yml` sets the image's through `bake.yml`'s `meta-annotations`.

## Setup (once)

Do this for each package: `devcontainer`, `claude-kit`, and `codex-kit`.

1. **The first push creates the package**, under the repository owner and linked to this repository. If it's created private, change it to **Public** in **Package settings** (a one-way change).
2. **Grant the repository Write** in **Package settings → Manage Actions access**. Retention deletion, once implemented, needs **Admin**. Add no other repositories.
3. **Restrict people.** Under **Manage access**, grant no users or teams beyond the owner's admins. All writes come from this repository's workflow.

## Workflow permissions

| Job | `permissions` | Login |
| --- | --- | --- |
| `build` (`bake.yml`) | `contents: read`, `packages: write`, `id-token: write` (signing) | `registry-auths` with `github.actor` and `GITHUB_TOKEN`, and `dhi.io` with `DOCKERHUB_TOKEN` for the base |
| `tag-ghcr` | `contents: read`, `packages: write` | `oras` login with `GITHUB_TOKEN` |
| `verify` | `contents: read`, `packages: read` | none (public) |
| `promote` (environment `quay`) | `contents: read`, `packages: read`, `id-token: write` (Quay federation) | `oras` login with `GITHUB_TOKEN` |

`GITHUB_TOKEN` is created for each run and expires when the run ends. It isn't a stored secret.

## Synchronization and recovery

The two registries can't update atomically. Synchronization is complete when tags resolve to the same digests and the required artifacts are discoverable in both. Recovery resumes the same publication from its recorded digest and never rebuilds ([data model](../data-model.md#mirroring-and-recovery)):

- **Test failure:** keep the result, logs, and digest, and open or update an issue. Synchronization continues.
- **Copy failure:** retry with backoff, then mark the publication incomplete and alert. Never delete images as recovery.
- **Partial tagging:** retry the missing tags. An existing date tag with a different digest is a conflict to report, never an overwrite.
- **Older run recovery:** restore missing snapshots and artifacts, but never move a mutable tag back over a newer publication.
- **Partial build push:** inspect the registry before retrying, and recover the existing publication instead of replacing its tag.

The workflow summary reports test status and synchronization status separately.

## Retention

Same as Quay: currently everything is kept. Under any future policy, a snapshot must never leave GHCR before it leaves Quay, and its `sha256-*` referrer tags stay as long as the image does.

## Known risk

`bake.yml` signs on GHCR through the referrer fallback. On the first run, confirm that signing succeeds with only the recovery tag, and that `promote` carries the signatures to Quay.
