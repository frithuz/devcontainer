# registry.frithuz.dev (pnpr)

The image is also published to **`registry.frithuz.dev/frithuz/devcontainer`**, Git to **`registry.frithuz.dev/frithuz/git`**, and the sandbox kits to **`registry.frithuz.dev/frithuz/claude-kit`** and **`registry.frithuz.dev/frithuz/codex-kit`**. The registry runs **pnpr**, pnpm's registry server (0.1.0-alpha.17 since 2026-10-31, replacing zot, with every image, tag, and referrer migrated at the same digest). This page covers the one-time setup in pnpr and GitHub that the [publish workflow](../maintenance.md#publishing-publishyml) and the [kits' publish workflow](../maintenance.md#publishing-the-kits) depend on.

Only the **`promote-frithuz`** jobs write to it: `publish.yml`'s for the image, `publish-kits.yml`'s for each kit, and `publish-git.yml`'s for Git. Each runs alongside its workflow's Quay `promote`, under the same condition. It copies the image, with its signatures, from the [GHCR mirror](ghcr.md) (or, for Git, from Quay when nothing was rebuilt) and applies the tags. It runs in the GitHub environment **`registry.frithuz.dev`** and logs in as the pnpr account **`ci-frithuz`** with a long-lived token, `PNPR_TOKEN`. pnpr's GitHub OIDC support covers npm publishes only, not OCI pushes, so the job's OIDC token isn't accepted here.

## 1. The `registry.frithuz.dev` environment

The environment holds `PNPR_TOKEN`, so only jobs that name it can log in, and its branch rule decides which runs may enter it. The `sign` jobs run in it too, because [OpenBao](openbao.md#1-what-openbao-trusts) trusts its OIDC subject, which uses the repository's immutable prefix ([quayio.md](quayio.md#the-repositorys-immutable-subject)):

```text
repo:frithuz@306324456/devcontainer@1433350495:environment:registry.frithuz.dev
```

Don't rename or remove the environment: OpenBao's `cosign-sign` role is bound to that subject.

In **Settings → Environments → registry.frithuz.dev**:

| Setting | Value | Why |
| --- | --- | --- |
| Deployment branches and tags | **Selected branches and tags**, with the one rule `main` (branch) | Only runs on `main` can enter the environment, so PRs, forks, and other branches never see `PNPR_TOKEN` or mint the subject |
| Required reviewers | None | As for [`quay`](quayio.md#the-quay-environment) |
| Environment secrets | `PNPR_TOKEN` | The `ci-frithuz` token. Kept here rather than as a repository secret so the branch rule guards it |

The environment was created with:

```sh
gh api -X PUT repos/frithuz/devcontainer/environments/registry.frithuz.dev \
  --input - <<<'{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
gh api -X POST repos/frithuz/devcontainer/environments/registry.frithuz.dev/deployment-branch-policies \
  -f name=main -f type=branch
```

## 2. The pnpr account

- **`ci-frithuz` may push to any `frithuz/*` repository** and nothing else. It can't delete; only an admin can.
- **The username is checked against the token's account**, so the login must use `ci-frithuz` exactly.
- **Rotating the token:** sign in to <https://registry.frithuz.dev/-/ui/> as `ci-frithuz`, create a token, and store it with `gh secret set PNPR_TOKEN --env registry.frithuz.dev`. Revoke the old one once a promote has succeeded with the new one.
- **Signatures aren't checked by pnpr.** It stores and serves cosign bundles as referrers, but doesn't verify them and doesn't show who signed an image. The check is `sign`'s `cosign verify` against GHCR before anything is promoted, and anyone pulling can run the same check ([openbao.md](openbao.md#4-verifying-an-image)).

## 3. The workflow

Each `promote-frithuz` names `environment: registry.frithuz.dev` and needs no `id-token` permission. Its **Copy and tag** step receives `PNPR_TOKEN` through the step's `env`, logs `oras` in once as `ci-frithuz` with `--password-stdin`, copies the image or kit with its referrers by digest, untagged, and then `oras tag` applies the tags (`build-<run id>` and `latest`, or Git's version). A kit is copied byte for byte, so the index annotations the kit frontend writes, the descriptor among them, survive.

- **The login doesn't expire mid-copy.** pnpr answers with a Bearer challenge, and `oras` exchanges the stored credential at `/v2/token` for five-minute tokens scoped to one repository, fetching new ones as it goes. There's no retry loop: `oras` already retries transient HTTP failures, and a rerun of the job skips the blobs that were copied.
- **pnpr has the Referrers API**, so the copy requires it (`--to-distribution-spec v1.1-referrers-api`), as for Quay.

## 4. Pulling

The registry needs a login to read. Sign in at <https://registry.frithuz.dev/-/ui/> with your existing password, create a token there, and use it as the password:

```sh
oras login registry.frithuz.dev --username <you>
docker login registry.frithuz.dev --username <you>
```

zot API keys no longer work.

## 5. Verify

- **Login:** run `publish-git.yml` or `publish-kits.yml` manually on `main` with promotion enabled. The step should print `Login Succeeded`, and the copy should finish. Run it the same way from another branch: `promote-frithuz` should fail before it starts because the environment's branch rule refuses it.
- **Promotion:** from a machine logged in to `registry.frithuz.dev`:

  ```sh
  oras repo tags registry.frithuz.dev/frithuz/<repo>
  oras discover --distribution-spec v1.1-referrers-api registry.frithuz.dev/frithuz/<repo>@<digest>
  cosign verify --key cosign.pub registry.frithuz.dev/frithuz/<repo>@<digest>
  ```

  The tags list the new tag, `discover` shows the `application/vnd.dev.sigstore.bundle.v0.3+json` signature, and `cosign verify` passes.

A `publish-git.yml` run that skips compilation still copies the existing Quay artifact here, so a registry repair doesn't require rebuilding Git.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `PNPR_TOKEN` is empty, or the login sends an empty password | The job lacks `environment: registry.frithuz.dev`, or the secret is missing from the environment |
| Login returns 401 | The token was revoked or mistyped, or the username isn't `ci-frithuz` |
| Login succeeds, then the push returns 403 | The repository isn't under `frithuz/`, or `ci-frithuz` lost push rights |
| `cosign verify` reports `no signatures found` | The copy ran without `--to-distribution-spec v1.1-referrers-api`, or before `sign` |
