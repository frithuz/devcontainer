# Quay.io

The image is published to **`quay.io/frithuz/devcontainer`**. This page covers the one-time setup in Quay and GitHub that the [publish workflow](../maintenance.md#publishing-publishyml) depends on.

Quay is the **default distribution registry**. Only one job writes to it: **`promote`**, our own job. It copies the image, with its signatures and source artifacts, from the [GHCR mirror](ghcr.md), confirms the source is attached, and applies the tags. Promotion runs independently of tests and continues when tests fail. It authenticates as a single robot account, **`frithuz+promote`**, using **OIDC federation only**. No Quay token is stored anywhere, in GitHub or elsewhere.

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
| Robot federation | Issuer `https://token.actions.githubusercontent.com`, subject `<prefix>:ref:refs/heads/main` (see [section 4](#4-oidc-federation)) |
| Robot token | **Never copied or stored.** It exists but isn't used. If it's ever exposed, regenerate it to invalidate it. Federation keeps working |

Steps:
1. Create the robot with the name and description above.
2. In **Add to repository**, select `devcontainer` with **Write**. Skip the team and default-permission steps.
3. Set up federation as described in [section 4](#4-oidc-federation).

The robot doesn't need **Admin**. That would let it change visibility, permissions, and repository settings.

## 4. OIDC federation

### Get the repository's immutable subject

GitHub can issue OIDC subjects that use the repository's and owner's numeric IDs. The subject then can't be claimed by another repository that later takes over the same name.

1. In the GitHub repository, open **Settings → Actions → OIDC**.
2. Enable **Use immutable subject claim**.
3. Copy the **Default subject claim prefix**. It has the form `repo:<owner>@<owner-id>/<repo>@<repo-id>`.

### Configure federation on the robot

1. In **Robot Accounts**, open the menu (⋮) on `frithuz+promote`, choose **Set robot federation**, and click **+**.
2. Enter:
   - **Issuer URL:** `https://token.actions.githubusercontent.com`
   - **Subject:** `<prefix>:ref:refs/heads/main`
3. Save.

The subject pins token minting to workflow runs on `main`. Scheduled runs execute on the default branch, so they match too. Runs from PRs, forks, and other branches get a different subject, and Quay rejects their tokens.

**Optional, stricter:** run `promote` in a GitHub environment (e.g. `quay`, restricted to `main`, with required reviewers if wanted). Federate on `<prefix>:environment:quay` instead. With an environment set, GitHub's subject names the environment instead of the ref.

### Use it in the workflow

The job needs `id-token: write`. It requests a GitHub OIDC token, exchanges it for a one-hour Quay token, masks both, and logs `oras` in:

```yaml
promote:
  needs: [build, attach-ghcr]
  runs-on: ubuntu-26.04
  permissions:
    contents: read
    packages: read   # copy from the GHCR mirror
    id-token: write  # Quay federation
  env:
    QUAY_ROBOT: frithuz+promote
  steps:
    - name: Log in to GHCR
      shell: bash
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }} # automatic per-run token, not a stored secret
      run: |
        set -euo pipefail
        printf '%s' "${GH_TOKEN}" | oras login ghcr.io --username "${{ github.actor }}" --password-stdin
    - name: Log in to Quay with OIDC federation
      shell: bash
      run: |
        set -euo pipefail
        oidc=$(curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
          "${ACTIONS_ID_TOKEN_REQUEST_URL}" | jq -r .value)
        echo "::add-mask::${oidc}"
        token=$(curl -fsS --user "${QUAY_ROBOT}:${oidc}" \
          https://quay.io/oauth2/federation/robot/token | jq -r .token)
        echo "::add-mask::${token}"
        printf '%s' "${token}" | oras login quay.io --username "${QUAY_ROBOT}" --password-stdin
    # ... copy by digest with referrers, confirm source, tag (see maintenance.md#workflow and legal.md#publishing)
```

- **Token lifetime is one hour.** That matches Quay's one-hour protection for untagged pushes, which `promote` already has to finish within. Log in right before copying. If the job ever grows past an hour, log in again.
- Requests without an explicit `audience` parameter use GitHub's default `aud`. Quay's federation config takes only an issuer and a subject.

## 5. Verify

- **Federation:** run `publish.yml` manually on `main` (`workflow_dispatch`). The Quay login step should print `Login Succeeded`. To check that it's rejected elsewhere, run the same login step from another branch: the exchange should fail with an auth error.
- **No stored credentials:** the repository should have no Actions secrets, and the organization only `OP_INTEGRATION_KEY` if [1Password](1password.md) is ever adopted.
- **Promotion:** after a run, the Quay tags point at the same digests as the GHCR tags, and the signatures verify against the Quay reference.
- **Independent testing:** a deliberately failing test still allows `promote` to finish. The workflow reports the test failure and the successful sync separately. Copy failures retry and report incomplete synchronization; recovery uses the same digest ([GHCR recovery](ghcr.md#synchronization-and-recovery)).
- **Referrers:** check that the source artifact is attached:

  ```sh
  oras discover --distribution-spec v1.1-referrers-api \
    --artifact-type application/vnd.frithuz.devcontainer.source.v1 \
    quay.io/frithuz/devcontainer:main
  ```

- **Referrer retention:** source artifacts are untagged manifests that reach their image only through `subject`. Quay protects digest-only pushes with a hidden temporary tag that expires after an hour by default. Quay's newer garbage collector keeps manifests that have a subject, but whether quay.io keeps untagged referrers indefinitely isn't documented. After the first publish, run the `oras discover` check above again **after more than an hour**, and again **after more than 14 days** (Quay's default Time Machine window). If the artifact disappears, also give it a tag (e.g. `source-<subject-digest-hex>`) when attaching. A tag keeps it under normal tag retention.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Exchange returns 401/403 | The subject doesn't match: wrong ref, a job using an `environment`, or the mutable instead of the immutable prefix. Decode the OIDC token's `sub` claim (it's a JWT) and compare it with the federation entry |
| `ACTIONS_ID_TOKEN_REQUEST_URL` is empty | The job is missing `permissions: id-token: write` |
| Repository is private after the first promote | It was created by the push. Make it public in **Settings** |
| The robot can reach other repositories | An organization **Default Permission** or team membership grants it. Remove it (see [section 1](#1-organization)) |
| A step fails with 401 halfway through `promote` | The token expired (more than an hour old). Log in again before continuing |
| Index missing on Quay after a failed `promote` | The untagged copy outlived Quay's one-hour temporary tag and was garbage-collected. Re-run `promote`: it copies again from GHCR |
