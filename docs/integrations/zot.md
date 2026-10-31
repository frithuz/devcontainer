# registry.frithuz.dev (zot)

The image is also published to **`registry.frithuz.dev/frithuz/devcontainer`**, a self-hosted [zot](https://zotregistry.dev) registry, and the sandbox kits to **`registry.frithuz.dev/frithuz/claude-kit`** and **`registry.frithuz.dev/frithuz/codex-kit`**. This page covers the one-time setup in zot and GitHub that the [publish workflow](../maintenance.md#publishing-publishyml) and the [kits' publish workflow](../maintenance.md#publishing-the-kits) depend on.

Only the **`promote-frithuz`** jobs write to it: `publish.yml`'s for the image, and `publish-kits.yml`'s for each kit. Each runs alongside its workflow's Quay `promote`, under the same condition: only runs that tag `latest`. It copies the image, with its signatures, from the [GHCR mirror](ghcr.md) and applies the tags. It runs in the GitHub environment **`registry.frithuz.dev`** and authenticates with **zot's OIDC workload identity** (zot v2.1.19 or later). zot verifies the job's GitHub OIDC token itself. There's no token exchange service and no stored credential.

## 1. The `registry.frithuz.dev` environment

When a job names an environment, GitHub's OIDC subject names the environment instead of the ref, so zot trusts the environment and the environment decides which runs may use it. The `sign` jobs run in it too, because [OpenBao](openbao.md#1-what-openbao-trusts) trusts the same subject. The subject uses the repository's immutable prefix ([quayio.md](quayio.md#the-repositorys-immutable-subject)):

```text
repo:frithuz@306324456/devcontainer@1433350495:environment:registry.frithuz.dev
```

In **Settings → Environments → registry.frithuz.dev**:

| Setting | Value | Why |
| --- | --- | --- |
| Deployment branches and tags | **Selected branches and tags**, with the one rule `main` (branch) | Only runs on `main` can enter the environment. PRs, forks, and other branches can't mint the subject |
| Required reviewers | None | As for [`quay`](quayio.md#the-quay-environment) |
| Environment secrets and variables | None | zot needs no stored credential |

The environment was created with:

```sh
gh api -X PUT repos/frithuz/devcontainer/environments/registry.frithuz.dev \
  --input - <<<'{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
gh api -X POST repos/frithuz/devcontainer/environments/registry.frithuz.dev/deployment-branch-policies \
  -f name=main -f type=branch
```

## 2. zot configuration

Under `http` in zot's config:

```json
"auth": {
  "bearer": {
    "realm": "https://registry.frithuz.dev/zot/auth/token",
    "service": "registry.frithuz.dev",
    "oidc": [
      {
        "issuer": "https://token.actions.githubusercontent.com",
        "audiences": ["registry.frithuz.dev"],
        "claimMapping": {
          "validations": [
            {
              "expression": "claims.sub == 'repo:frithuz@306324456/devcontainer@1433350495:environment:registry.frithuz.dev'",
              "message": "only the promote-frithuz jobs may log in"
            }
          ],
          "username": "claims.sub"
        }
      }
    ]
  }
},
"accessControl": {
  "repositories": {
    "frithuz/devcontainer": {
      "policies": [
        {
          "users": ["repo:frithuz@306324456/devcontainer@1433350495:environment:registry.frithuz.dev"],
          "actions": ["read", "create", "update"]
        }
      ]
    },
    "frithuz/claude-kit": {
      "policies": [
        {
          "users": ["repo:frithuz@306324456/devcontainer@1433350495:environment:registry.frithuz.dev"],
          "actions": ["read", "create", "update"]
        }
      ]
    },
    "frithuz/codex-kit": {
      "policies": [
        {
          "users": ["repo:frithuz@306324456/devcontainer@1433350495:environment:registry.frithuz.dev"],
          "actions": ["read", "create", "update"]
        }
      ]
    }
  }
}
```

- **`realm` and `service` are required for `oras login`.** zot advertises `realm` in its `WWW-Authenticate` challenge, and `oras` sends the OIDC token as the password to `/zot/auth/token`, which hands it back as the registry token. The username is ignored. Without `realm`, the login fails.
- **The validation pins the subject.** Any GitHub Actions token is signed by the same issuer, so the issuer and audience alone would admit any repository that asks for this audience. Both workflows run in this repository and the same environment, so they share the subject.
- **Access is deny-by-default.** An OIDC identity that no policy lists gets a 403, so each repository has its own policy. `update` moves tags, and `delete` isn't needed.
- **Anonymous pulls.** With `bearer.oidc` set, zot rejects requests without a token before access control runs (as of v2.1.21), so an `anonymousPolicy` doesn't make the image public. Public pulls need a second, read-only zot instance on another hostname, or a token service such as [oci-token-server](https://github.com/panxiao81/oci-token-server) as `upstreamTokenEndpoint`.

## 3. The workflow

Each `promote-frithuz` names `environment: registry.frithuz.dev` and has `id-token: write`. Its **Copy and tag** step requests a GitHub OIDC token for the audience `registry.frithuz.dev` (`ZOT_AUDIENCE`), masks it, and logs `oras` in with it. It then copies the image or kit with its referrers from GHCR by digest, untagged, and `oras tag` applies `build-<run id>` and `latest`. A kit is copied byte for byte, so the index annotations the kit frontend writes, the descriptor among them, survive.

- **The token lasts five minutes.** zot reuses GitHub's token as the registry token and can't refresh it, so a copy can outlive its login. The step tries the copy up to three times, logging in with a fresh token each time. `oras cp` skips blobs that are already in zot, so each attempt continues where the last one stopped. It logs in again before tagging.
- **The audience has to match.** If `audiences` in zot's config changes, change `ZOT_AUDIENCE` to match.
- **zot has the Referrers API**, so the copy requires it, as for Quay.

## 4. Verify

- **Login:** push to `main`, or run `publish.yml` manually on `main` with **Also tag the built image as latest, and promote it to Quay and registry.frithuz.dev** ticked. The step should print `Login Succeeded`. Run it the same way from another branch: `promote-frithuz` should fail before it starts because the environment's branch rule refuses it.
- **Promotion:** after a run, `registry.frithuz.dev/frithuz/devcontainer`'s tags point at the same digests as GHCR's, and the signatures verify against the zot reference. After a `publish-kits` run, each kit's tags there point at the same digests as on GHCR.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Login returns 401 | The audience doesn't match (`ZOT_AUDIENCE` against `audiences`), or the subject validation fails: a job without the environment, or the mutable instead of the immutable prefix. Decode the token (it's a JWT) and compare its `aud` and `sub` claims with zot's config |
| Login fails without reaching `/zot/auth/token` | `bearer.realm` isn't set, or isn't reachable at `https://registry.frithuz.dev/zot/auth/token` |
| Login succeeds, then the push returns 403 | The identity isn't in `accessControl` for that repository (`frithuz/devcontainer`, `frithuz/claude-kit`, or `frithuz/codex-kit`), or lacks `create` or `update` |
| `ACTIONS_ID_TOKEN_REQUEST_URL` is empty | The job is missing `permissions: id-token: write` |
| Every copy attempt fails with 401 partway through | Each attempt outlives its five-minute token before copying any new blob. Copy the platforms one at a time, or raise the attempts |
