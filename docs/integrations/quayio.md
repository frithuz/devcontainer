# Quay.io

The image is published to **`quay.io/frithuz/devcontainer`**. This page covers the one-time setup in Quay and GitHub that the [publish workflow](../maintenance.md#publishing-publishyml) depends on.

Quay is the **default distribution registry**. Only one job writes to it: **`promote`**, our own job. It copies the image, with its signatures, source indexes, and source images, from the [GHCR mirror](ghcr.md), confirms the source is attached, and applies the tags. For now `promote` runs only on runs that tag `latest`, which are pushes to `main` and manual runs that ask for it ([maintenance.md](../maintenance.md#publishing-publishyml)); every other run stays on GHCR. Promotion runs independently of tests and continues when tests fail. It runs in the GitHub environment **`quay`** and authenticates as a single robot account, **`frithuz+promote`**, using **OIDC federation only**. No Quay token is stored anywhere, in GitHub or elsewhere.

## 1. Organization

In **Organizations → frithuz → Settings**:

| Setting | Value | Why |
| --- | --- | --- |
| **Default Permissions** | None for any robot or team | Default permissions grant access to *every new repository*. The robot must only ever reach `devcontainer` |
| **Teams** | `frithuz+promote` isn't a member of any team | Team membership would grant whatever the team can reach |

## 2. Repository `frithuz/devcontainer`

1. **Organizations → frithuz → Create New Repository**: name `devcontainer`, visibility **Public**.
2. In **devcontainer → Settings**:

| Setting | Value |
| --- | --- |
| Visibility | **Public** |
| User and Robot Permissions | `frithuz+promote`: **Write**. No other robots |
| Description | What the image is, plus the directions for fetching copyleft source ([legal.md](../legal.md#finding-the-source)) |

Create the repository before the first promote. If a push creates it, Quay makes it **private**.

## 3. Robot account `frithuz+promote`

Create it under **Organizations → frithuz → Robot Accounts → Create Robot Account**. The wizard asks for a name and description, then offers optional steps: add to a team, add to repositories, and default permissions. Set them exactly as below and leave every other optional step empty. Federation only works for robots that belong to an **organization**, not to a user (as of Quay 3.16).

| Field | Value |
| --- | --- |
| Name | `promote` (full name `frithuz+promote`) |
| Description | `publish.yml promote job: copies images and referrers from the GHCR mirror, applies tags. OIDC federation only.` |
| Add to team | None |
| Repository permissions | `devcontainer`: **Write** (push manifests and referrers, create and move tags) |
| Default permissions | None |
| Robot federation | Issuer `https://token.actions.githubusercontent.com`, subject `repo:frithuz@306324456/devcontainer@1433350495:environment:quay`, OIDC audiences `quay` (see [section 4](#4-oidc-federation)) |
| Robot token | **Never copied or stored.** It exists but isn't used. If it's ever exposed, regenerate it to invalidate it. Federation keeps working |

Steps:
1. Create the robot with the name and description above.
2. In **Add to repository**, select `devcontainer` with **Write**. Skip the team and default-permission steps.
3. Set up federation as described in [section 4](#4-oidc-federation).

The robot doesn't need **Admin**. That would let it change visibility, permissions, and repository settings.

## 4. OIDC federation

### The repository's immutable subject

GitHub can issue OIDC subjects that use the repository's and owner's numeric IDs. The subject then can't be claimed by another repository that later takes over the same name.

**Use immutable subject claim** is enabled under **Settings → Actions → OIDC**. The repository's subject prefix is:

```text
repo:frithuz@306324456/devcontainer@1433350495
```

The IDs belong to the owner `frithuz` and the repository `devcontainer`. Renaming keeps them. Transferring the repository to another owner changes the owner ID, and recreating it changes the repository ID. Either one needs a new federation entry.

### The `quay` environment

`promote` runs in the GitHub environment `quay`. When a job names an environment, GitHub's subject names the environment instead of the ref, so the federation entry trusts the environment and the environment decides which runs may use it.

In **Settings → Environments → quay**:

| Setting | Value | Why |
| --- | --- | --- |
| Deployment branches and tags | **Selected branches and tags**, with the one rule `main` (branch) | Only runs on `main`, including scheduled runs, can enter the environment. PRs, forks, and other branches can't mint the subject |
| Required reviewers | None | `promote` already runs only when someone starts a run with `latest` ticked. If scheduled runs promote later, reviewers would make them wait for approval. Add reviewers only if every promotion should be approved by hand |
| Environment secrets and variables | None | Federation needs no stored credential |

The environment was created with:

```sh
gh api -X PUT repos/frithuz/devcontainer/environments/quay \
  --input - <<<'{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
gh api -X POST repos/frithuz/devcontainer/environments/quay/deployment-branch-policies \
  -f name=main -f type=branch
```

### Configure federation on the robot

1. In **Robot Accounts**, open the menu (⋮) on `frithuz+promote`, choose **Set robot federation**, and click **+**.
2. Enter:
   - **Issuer URL:** `https://token.actions.githubusercontent.com`
   - **Subject:** `repo:frithuz@306324456/devcontainer@1433350495:environment:quay`
   - **OIDC audiences:** `quay` (the default)
3. Save.

A job without `environment: quay`, or a run the environment's branch rule turns away, gets a different subject, and Quay rejects its token.

### Use it in the workflow

The `promote` job in [`publish.yml`](../../.github/workflows/publish.yml) names `environment: quay` and has `id-token: write`. Its **Log in to Quay with OIDC federation** step requests a GitHub OIDC token for the audience `quay` (`QUAY_AUDIENCE`), exchanges it for a one-hour Quay token, masks both, and logs `oras` in. It then copies the image with its referrers from GHCR by digest, untagged. The referrers include the source indexes, and each source index lists its source images, so the source arrives without `source-*` tags. `scripts/source-indexes.sh check` then requires one source index per subject, with everything it lists in Quay, before `oras tag` applies `build-<run id>` and `latest`.

- **Token lifetime is one hour.** That matches Quay's one-hour protection for untagged pushes, which `promote` already has to finish within. Log in right before copying. If the job ever grows past an hour, log in again.
- **The audience has to match.** Quay checks the token's `aud` against the federation entry's **OIDC audiences**, which default to `quay`. Without an `audience` parameter, GitHub sets `aud` to `https://github.com/frithuz`, and Quay rejects the token. Nothing in GitHub's settings controls the audience: the job asks for it when it requests the token. If the audience in Quay changes, change `QUAY_AUDIENCE` to match. Quay still accepts entries with no audiences but logs them as deprecated, so keep one set.

## 5. Verify

- **Federation:** push to `main`, or run `publish.yml` manually on `main` (`workflow_dispatch`) with **Also tag the built image as latest, and promote it to Quay** ticked. A manual run without it, or a scheduled run, skips `promote`. The Quay login step should print `Login Succeeded`. To check that it's rejected elsewhere, run the workflow the same way from another branch: `promote` should fail before it starts because the `quay` environment's branch rule refuses it.
- **No stored credentials:** the repository should have no Actions secrets, and the organization only `OP_INTEGRATION_KEY` if [1Password](1password.md) is ever adopted.
- **Promotion:** after a run, the Quay tags point at the same digests as the GHCR tags, and the signatures verify against the Quay reference.
- **Independent testing:** a deliberately failing test still allows `promote` to finish. The workflow reports the test failure and the successful sync separately. Copy failures retry and report incomplete synchronization; recovery uses the same digest ([GHCR recovery](ghcr.md#synchronization-and-recovery)).
- **Referrers:** check that the source index is attached, and that its source images resolve:

  ```sh
  oras discover --distribution-spec v1.1-referrers-api \
    --artifact-type application/vnd.frithuz.devcontainer.source.v1 \
    quay.io/frithuz/devcontainer:main
  ```

- **Referrer retention:** in Quay, source indexes are untagged manifests that reach their image only through `subject`, and source images are untagged too, reached only through the source indexes that list them. Quay protects digest-only pushes with a hidden temporary tag that expires after an hour by default. Quay's newer garbage collector keeps manifests that have a subject, and an index keeps what it lists, but whether quay.io keeps untagged referrers indefinitely isn't documented. After the first publish, run `scripts/source-indexes.sh check --referrers api quay.io/frithuz/devcontainer <digest>` again **after more than an hour**, and again **after more than 14 days** (Quay's default Time Machine window). If a source index or source image disappears, also give each source index a tag (e.g. `source-index-<subject-digest-hex>`) in `promote`. A tag keeps it, and everything it lists, under normal tag retention.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Exchange returns 401/403 | The audience doesn't match (`QUAY_AUDIENCE` against the entry's OIDC audiences), or the subject doesn't match: a job without `environment: quay`, a different environment name, or the mutable instead of the immutable prefix. Decode the OIDC token (it's a JWT) and compare its `aud` and `sub` claims with the federation entry |
| `ACTIONS_ID_TOKEN_REQUEST_URL` is empty | The job is missing `permissions: id-token: write` |
| Login succeeds, then the first push returns `unauthorized` | The robot can read the public repository but can't write to it. Give `frithuz+promote` **Write** on `devcontainer` (see [section 3](#3-robot-account-frithuzpromote)) |
| `check` finds no source index on Quay | The subject has none on GHCR either (the `sources` job's summary lists them), or Quay didn't take a referrer. The copy step requires the Referrers API, so the copy itself would have failed |
| Repository is private after the first promote | It was created by the push. Make it public in **Settings** |
| The robot can reach other repositories | An organization **Default Permission** or team membership grants it. Remove it (see [section 1](#1-organization)) |
| A step fails with 401 halfway through `promote` | The token expired (more than an hour old). Log in again before continuing |
| Index missing on Quay after a failed `promote` | The untagged copy outlived Quay's one-hour temporary tag and was garbage-collected. Re-run `promote`: it copies again from GHCR |
