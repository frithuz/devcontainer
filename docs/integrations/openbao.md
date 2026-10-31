# OpenBao (cosign signing key)

Every image and kit that's promoted carries a **key-based cosign signature** from a key held in a self-hosted [OpenBao](https://openbao.org) at **`https://vault.frithuz.dev`**: transit key **`cosign`**, ECDSA P-256, referenced by cosign as `hashivault://cosign`. The key can't be exported, so it never leaves OpenBao. Its public half is committed as [`cosign.pub`](../../cosign.pub). This page covers what OpenBao trusts, what the workflows do with it, and how to verify an image.

Only the **`sign`** jobs use it: `publish.yml`'s for the image, and `publish-kits.yml`'s for each kit. Each runs after its workflow pushes to GHCR, under the promote jobs' condition: only runs that tag `latest`. It signs the **image index digest** on GHCR, and `promote` and `promote-frithuz` wait for it, then copy the signature to Quay and `registry.frithuz.dev` with the other referrers. It runs in the GitHub environment **`registry.frithuz.dev`** and logs in with the job's GitHub OIDC token. No OpenBao credential is stored.

The keyless Sigstore signatures `bake.yml` makes are unchanged ([maintenance.md](../maintenance.md#registry-and-signing)). The two answer different questions: the keyless ones name the workflow that built the image, and this one says the image was published by this repository's `main`, with a key that doesn't depend on GitHub's or Sigstore's identity.

## 1. What OpenBao trusts

The JWT auth mount **`jwt-github`** trusts GitHub's OIDC issuer, and its role **`cosign-sign`** binds:

| Claim | Value | Why |
| --- | --- | --- |
| `aud` | `vault.frithuz.dev` | The job asks for this audience when it requests the token (`OPENBAO_AUDIENCE`). A token minted for Quay can't be replayed here |
| `sub` | `repo:frithuz@306324456/devcontainer@1433350495:environment:registry.frithuz.dev` | The repository's immutable prefix ([quayio.md](quayio.md#the-repositorys-immutable-subject)) and the environment. Any other job, branch, or repository gets a different subject and HTTP 400 |

The subject names the environment, so the environment decides which runs may sign: **`registry.frithuz.dev`**, which only `main` can deploy to ([registry-frithuz.md](registry-frithuz.md#1-the-registryfrithuzdev-environment)). The `sign` jobs share it with `promote-frithuz`, so OpenBao would admit a `promote-frithuz` job too, and `sign` could read `PNPR_TOKEN`. Neither job uses the other's service. If they should be told apart, give `sign` its own environment and bind the role to that subject.

## 2. What the token can do

A login returns a **batch token**: ten minutes, not renewable, and not stored anywhere by OpenBao. Its policy allows only:

- `transit/sign/cosign*`: sign with the `cosign` key.
- reading `transit/keys/cosign`: cosign reads the key's public half and type.

It can't export, rotate, or delete the key, read any other key, or reach anything outside transit. The job requests it right before signing, masks it and the OIDC token, and hands it to cosign as `VAULT_TOKEN`, with `VAULT_ADDR`. cosign's `hashivault` KMS reads those two, and uses the transit mount `transit` because `TRANSIT_SECRET_ENGINE_PATH` is unset. No step that handles either token runs with `set -x`.

## 3. The workflows

`sign`, in each workflow:

1. checks out `cosign.pub`, installs cosign (v3.1.4, through `sigstore/cosign-installer`), and logs in to GHCR with `GITHUB_TOKEN`;
2. resolves the digest: `build`'s output in `publish.yml`, and `build-<run id>` on GHCR in `publish-kits.yml`, as its promote jobs do;
3. logs in to OpenBao;
4. runs `cosign sign --yes --key hashivault://cosign <ghcr repository>@<digest>`;
5. runs `cosign verify --key cosign.pub` against the same reference, so a signature that doesn't verify fails the run before anything is promoted.

`promote` and `promote-frithuz` need `sign` and run only when it succeeds.

- **One signature covers the attestations.** The index lists each platform's image manifest and its buildx attestation manifest (SBOM and provenance) by digest. Signing the index signs all of them, so nothing is attested separately.
- **Where the signature is stored.** cosign v3 writes a Sigstore bundle (`application/vnd.dev.sigstore.bundle.v0.3+json`) as an OCI referrer of the index. GHCR has no Referrers API, so it lands under the index's `sha256-<digest>` fallback tag ([ghcr.md](ghcr.md#how-ghcr-differs-from-quay)). cosign appends to that tag's index and never deletes, so it works within GHCR's lack of `DELETE`. `oras cp -r --to-distribution-spec v1.1-referrers-api` reads the fallback tag and writes the bundle to Quay and registry.frithuz.dev as a real referrer.
- **Rekor.** cosign also records each signature in the public [Rekor](https://docs.sigstore.dev/logging/overview/) transparency log, which timestamps it. The entry holds the digest, the signature, and the public key, all public anyway. It stays on. If it's ever turned off, verifying a signature made without it needs `--insecure-ignore-tlog`.
- **Reruns add a signature.** Rerunning a `sign` job signs again, and the index then carries two bundles from the same key. Both verify, and the promote jobs copy both.

## 4. Verifying an image

With `cosign.pub` from this repository (cosign v3 or later):

```sh
cosign verify --key cosign.pub quay.io/frithuz/devcontainer@sha256:<digest>
```

The same works against `ghcr.io/frithuz/devcontainer`, `registry.frithuz.dev/frithuz/devcontainer`, and each registry's `claude-kit` and `codex-kit`. Verify by digest: a tag can move after you've checked it. cosign checks the Rekor entry too, so it needs network access to Sigstore's public infrastructure. `registry.frithuz.dev` needs a login to read ([registry-frithuz.md](registry-frithuz.md#4-pulling)).

The signature covers the index, so the SBOM and provenance are covered too, as long as you reach them through the verified digest, for example `docker buildx imagetools inspect <image>@<digest> --format '{{json .Provenance}}'`.

## 5. Verify the setup

- **Signing:** run `publish.yml` manually on `main` with **Also tag the built image as latest, and promote it to Quay and registry.frithuz.dev** ticked. `sign` should log in, sign, and verify, and both promote jobs should then run. Run `publish-kits.yml` the same way for the kits.
- **Every registry:** after each run, `cosign verify --key cosign.pub` passes for the new digest on `ghcr.io`, `quay.io`, and `registry.frithuz.dev`.
- **Rejection:** a run from another branch never reaches OpenBao, because the environment's branch rule refuses `sign` before it starts.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Login returns HTTP 400 | The token's claims don't match the role: a job without `environment: registry.frithuz.dev`, the mutable instead of the immutable subject prefix, or a different audience. The step prints OpenBao's response body, which names the failed check. Decode the OIDC token (it's a JWT) and compare its `aud` and `sub` with the role |
| `ACTIONS_ID_TOKEN_REQUEST_URL` is empty | The job is missing `permissions: id-token: write` |
| `cosign sign` returns 403 from OpenBao | The token expired (more than ten minutes since the login), or the policy no longer allows `transit/sign/cosign` |
| `cosign sign` fails pushing to GHCR | The job is missing `packages: write`, or the package doesn't grant this repository Write ([ghcr.md](ghcr.md#setup-once)) |
| `cosign verify` reports `no signatures found` on Quay or registry.frithuz.dev | The copy ran without the signature: check that `promote` and `promote-frithuz` ran after `sign`, and that the GHCR index has its `sha256-<digest>` tag |
| `cosign verify` fails with a key mismatch | `cosign.pub` doesn't match the transit key. Compare it with `bao read transit/keys/cosign` |
