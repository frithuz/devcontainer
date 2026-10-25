# GHCR (mirror)

`ghcr.io/<owner>/devcontainer` is a **public mirror** of the image. `docker/github-builder`'s `bake.yml` builds and pushes here first, and the `promote` job then copies the image to Quay. **Quay (`quay.io/frithuz/devcontainer`) is the source of truth.** GHCR carries the same images, tags, signatures, and source artifacts.

The mirror exists for two reasons:

- **`bake.yml` can push to it without a stored secret.** It logs in with GitHub's automatic `GITHUB_TOKEN`. Quay would need a static robot token, because `bake.yml` has no Quay identity type.
- **Fast, free pulls for GitHub Actions.** Runners pull from GHCR inside GitHub's network, which makes it the natural registry for CI consumers ([usage.md](../usage.md#which-registry)).

## How the two registries differ

| | Quay (source of truth) | GHCR (mirror) |
| --- | --- | --- |
| Gets new tags | Only after `verify` passes and source is attached | Immediately, from `bake.yml` |
| Referrers (signatures, source) | Native OCI Referrers API | Referrers tag fallback (`sha256-<digest>` tags) |
| How artifacts show in the UI | Linked to their image | As extra `sha256-*` tags and untagged versions |
| On a failed check | Unchanged | Rolled back to match Quay ([below](#rollback)) |
| Deletion | Registry API / Quay UI | GitHub Packages REST API only (registry `DELETE` returns 405) |

Because `bake.yml` tags GHCR directly, a new image is public on GHCR **before** `verify` and source attachment run. That gap is normally a few minutes. The `attach-ghcr` job runs immediately after the push to keep it short, and any later failure rolls GHCR back. Quay never has that gap.

## Setup (once)

1. **First push creates the package.** The `build` job pushes with `GITHUB_TOKEN`, which creates `devcontainer` under the repository owner, linked to this repository. Public visibility is fine. If GitHub creates it as private, change it to **Public** in **Package settings** (that change is one-way).
2. **Grant the repository Admin.** In **Package settings → Manage Actions access**, give this repository the **Admin** role. `GITHUB_TOKEN` can only *delete* package versions when the repository has Admin on the package, and rollback and retention both delete. Add no other repositories.
3. **Restrict people.** Under **Manage access**, grant no users or teams beyond the owner's admins. All writes come from this repository's workflow.

## Workflow permissions

| Job | `permissions` | Login |
| --- | --- | --- |
| `build` (`bake.yml`) | `contents: read`, `packages: write`, `id-token: write` (bake.yml signing and cache) | `registry-auths: - registry: ghcr.io / username: ${{ github.actor }} / password: ${{ secrets.GITHUB_TOKEN }}` |
| `attach-ghcr` | `contents: read`, `packages: write` | `oras login ghcr.io` with `GITHUB_TOKEN` |
| `verify` | `contents: read`, `packages: read` | none needed (public), or `container.credentials` with `GITHUB_TOKEN` |
| `promote` | `contents: read`, `packages: read`, `id-token: write` (Quay federation) | `oras login ghcr.io` with `GITHUB_TOKEN` |
| `rollback-ghcr` | `contents: read`, `packages: write` | `oras` and the GitHub REST API (`gh api`) with `GITHUB_TOKEN` |

`secrets.GITHUB_TOKEN` is created by GitHub for each run and expires when the run ends. It isn't a stored secret.

## Source artifacts on GHCR

GHCR is a public distribution point, so it needs the copyleft source just like Quay ([legal.md](../legal.md#publishing)). `attach-ghcr` attaches the bundles to the GHCR index and per-platform manifests right after `build`. GHCR has no Referrers API, so `oras` writes them through the referrers tag fallback:

- **One attach per subject.** Adding a second artifact to a subject rewrites its `sha256-<digest>` index, and the client then tries to `DELETE` the old one, which GHCR rejects with 405. All bundles go into **one** artifact per subject in a single `oras attach`. `bake.yml`'s signatures attach to the *attestation* manifests, which are different subjects.
- **The fallback tags are real tags.** Any GHCR retention or cleanup must keep `sha256-*` tags for as long as their subject image is kept.

`promote` then copies the image to Quay **with its referrers** (`oras cp -r`), so Quay receives the same signatures and source artifact, stored natively.

## Rollback

GHCR must never keep pointing at something Quay rejected. If `attach-ghcr`, `verify`, or `promote` fails, `rollback-ghcr` runs (`if: failure()`), and for each tag this run applied on GHCR:

- **The tag exists on Quay** (e.g. `:main`, `:latest`): point the GHCR tag back at the digest Quay's tag points to (`oras tag`). That digest is already on GHCR from an earlier run.
- **The tag doesn't exist on Quay** (e.g. a new `:YYYYMMDD`): delete the failed GHCR version, together with its children and fallback-tag referrers, through the REST API:

  ```text
  GET    /orgs/<org>/packages/container/devcontainer/versions        (or /user/... for a user-owned package)
  DELETE /orgs/<org>/packages/container/devcontainer/versions/<id>
  ```

  Delete referrers first, then the per-platform and attestation manifests, then the index.

The workflow still fails and opens an issue. The next run fixes forward.

## Retention

GHCR follows **the same retention as Quay**: a snapshot is removed from GHCR when it's removed from Quay, never earlier, and its `sha256-*` referrer tags go with it. The policy itself is still to be decided ([maintenance.md](../maintenance.md#tags-and-schedule)). The GPL rule is the same in both places: source stays available as long as its image is ([legal.md](../legal.md#retention)).

## Known risk

`bake.yml` signs on GHCR through the referrers tag fallback. Each attestation manifest is signed once, so no fallback index should need replacing. Confirm on the first run that `build`'s signing step succeeds, that `attach-ghcr` succeeds, and that `promote` copies both kinds of referrers to Quay.
