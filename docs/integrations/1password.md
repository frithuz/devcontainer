# 1Password

**Status: not in use yet.** No workflow needs a 1Password-managed secret today. Quay is reached with robot federation, and the GHCR mirror with the automatic `GITHUB_TOKEN` (see [maintenance.md](../maintenance.md#registry-and-signing)). This page defines how 1Password gets wired in when a job does need a credential.

## Policy

Credentials for workflows are never stored as GitHub secrets, with one exception: `DOCKERHUB_TOKEN`, which pulls the base from `dhi.io` and must reach `bake.yml` ([maintenance.md](../maintenance.md#registry-and-signing)). In order of preference:

1. **The service's own OIDC federation**, e.g. Quay robot federation or cloud workload identity. Nothing is stored anywhere.
2. **GitHub's automatic `GITHUB_TOKEN`**, for GitHub-hosted services such as GHCR.
3. **1Password Workload Identity**, for services that only issue static credentials. The credential lives in a 1Password Environment, and the workflow proves its identity to 1Password with GitHub OIDC to receive it at runtime.

## How Workload Identity works

1Password calls it **Workload Identity**. It's part of the Credential Broker, which is in **public preview**, and requires a **1Password Business** account. [`1password/load-secrets-action`](https://github.com/1Password/load-secrets-action#-workload-identity-public-preview) (v5+) exchanges the job's GitHub OIDC token for short-lived access to one **1Password Environment**, and loads **every** variable defined in it ([1Password docs](https://www.1password.dev/brokered-access/github-actions)).

The action takes three values:

| Variable | Kind | What it is |
| --- | --- | --- |
| `OP_WORKLOAD_ID` | GitHub **variable** (not secret) | Identifies the workload |
| `OP_ENVIRONMENT_ID` | GitHub **variable** (not secret) | Which 1Password Environment to load |
| `OP_INTEGRATION_KEY` | GitHub **organization secret** | *"Required to decrypt secrets in your team's workflows"* ([setup docs](https://www.1password.dev/brokered-access.md)) |

### The one bootstrap secret

`OP_INTEGRATION_KEY` is the single exception to the policy, and it's what 1Password's setup prescribes. It's a **decryption key, not an access credential.** Secrets are only released after the workflow's OIDC identity is verified against the Environment's restrictions, and every request is audit-logged. A leaked key, without a matching workflow run in this repository, yields nothing. It's created once per GitHub organization, not per secret.

Constraints:

- **Not available to `bake.yml` (or any reusable workflow we call).** Values loaded in our job can't be passed into a reusable workflow's `secrets:`, because GitHub drops masked job outputs. Workload Identity only serves **our own jobs**.
- **All-or-nothing per Environment.** The action loads every variable in the Environment, so create **one Environment per job purpose** with only what that job needs.
- **GitHub.com only.** GitHub Enterprise Server and Enterprise Cloud with data residency aren't supported. On GitHub Free, workflows in *private* repositories can't use it. This repository is public.
- **Preview.** Behavior and setup may change. Recheck the docs before relying on it.

## Setup

### 1. Connect the GitHub organization (1Password admin, once)

1. In 1Password, as an administrator, open the **Credential Broker** settings and create a **GitHub Actions** integration. Enter an integration name and the GitHub organization name, then select **Create integration**.
2. Save the generated **integration key** in a 1Password item (e.g. `GitHub Actions integration key – <org>`) in an admin-only vault.
3. In GitHub, open **Organization → Settings → Secrets and variables → Actions** and add an **organization secret**:
   - name: `OP_INTEGRATION_KEY`
   - value: the integration key
   - repository access: **selected repositories**, including only the repositories that use Workload Identity

### 2. Create an Environment per job (repository maintainer)

For each job that needs a credential:

1. In the 1Password desktop app, create an **Environment** named for the job (e.g. `devcontainer / <job>`), and add only the variables that job needs.
2. In the Environment, under **GitHub Actions**, select **Connect**, choose the organization's integration, and enter this repository's name.
3. **Restrict access** as tightly as the job allows: the specific **workflow** file, and the **`main` branch** or a **GitHub environment**. Then select **Add workflow**.
4. Record the Environment's `OP_WORKLOAD_ID` and `OP_ENVIRONMENT_ID` from the generated snippet as **repository variables** (Settings → Secrets and variables → Actions → **Variables**). They aren't secret.

### 3. Use it in the job

```yaml
some-job:
  runs-on: ubuntu-26.04
  permissions:
    contents: read
    id-token: write # lets the action request a GitHub OIDC token
  steps:
    - name: Load credentials from 1Password
      id: op
      uses: 1password/load-secrets-action@<sha> # v5
      env:
        OP_WORKLOAD_ID: ${{ vars.OP_WORKLOAD_ID_SOME_JOB }}
        OP_ENVIRONMENT_ID: ${{ vars.OP_ENVIRONMENT_ID_SOME_JOB }}
        OP_INTEGRATION_KEY: ${{ secrets.OP_INTEGRATION_KEY }}
    - name: Use a credential
      env:
        SOME_TOKEN: ${{ steps.op.outputs.SOME_TOKEN }}
      run: some-tool --token "$SOME_TOKEN"
```

- Prefer **step outputs** (`steps.<id>.outputs.<name>`) over `export-env: true`. Exported variables reach every later step in the job, while step outputs only go where they're referenced.
- For shell commands, pass outputs through the consuming step's `env` and quote the variable expansion. Don't interpolate secrets directly into `run:` scripts, where their contents could be interpreted as shell code.
- Pin the action by commit SHA. Dependabot's `github-actions` ecosystem keeps it current.
- Load credentials in the step right before they're used, and keep such jobs small.

## Verify

- Run the workflow on `main`: the load step succeeds and the audit log shows the access.
- Run the same workflow from another branch, or with the workflow restriction not matching: the load step must fail.
- Check that `OP_INTEGRATION_KEY` is the only organization secret, and that this repository's only repository secret is `DOCKERHUB_TOKEN`.
