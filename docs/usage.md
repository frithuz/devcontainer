# Usage

There is one image, built for `linux/amd64` and `linux/arm64`, with no per-context variants. Everything specific to a context lives in that context's configuration: `devcontainer.json`, the workflow's `container:` block, or a sandbox kit.

Consumers should reference a **scheduled snapshot by digest**, and let their own Dependabot keep it current:

```text
quay.io/frithuz/devcontainer:<YYYYMMDD>@sha256:<digest>
```

The available tags are described in [maintenance.md](maintenance.md#publishing-publishyml).

### Which registry

The same image, with the same tags and digests, is published to two registries:

| Registry | Use it for |
| --- | --- |
| `quay.io/frithuz/devcontainer` | **Default.** The source of truth: tags only ever point at verified images with their source attached |
| `ghcr.io/<owner>/devcontainer` | **GitHub Actions.** Pulls stay inside GitHub's network, so they're fast and free |

Digests are identical, so pinning `@sha256:<digest>` gives the same image from either one. GHCR gets a new image a few minutes before Quay, and rolls back if it fails verification. Pinning by digest avoids ever landing in that window.

## Editor devcontainers

In the consuming repository, `.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "project",
  "image": "quay.io/frithuz/devcontainer:<YYYYMMDD>@sha256:<digest>",
  "remoteUser": "agent",
  "updateRemoteUserUID": true
}
```

- Avoid Dev Container Features that install tools the image already provides. They drift from the pinned versions.
- Project-specific setup goes in `postCreateCommand`, not in a derived image, unless it's expensive.
- Agent credentials and config stay out of the image. Mount them or log in inside the container.
  - `~/.claude` can be mounted whole.
  - **Don't mount a whole `~/.codex`.** Codex's installed binaries live in `/home/agent/.codex/packages`, and a mount would hide them. Mount individual files (`auth.json`, `config.toml`) instead. See [tooling.md](tooling.md#agent-installers).

Consuming repos can enable Dependabot's `devcontainers` and `docker` ecosystems to bump the image reference.

### Docker on macOS hosts

**Never run Docker-in-Docker on a macOS host.** Running `dockerd` inside the container there causes corruption (see [architecture.md](architecture.md#never-run-dind-on-macos-hosts)). Use the host's daemon through its socket instead:

```jsonc
{
  "mounts": [
    "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"
  ]
}
```

Don't run `start-dockerd`. The image's `docker`, `buildx`, and `compose` CLIs work against the mounted socket. Depending on the backend, the socket may be owned by `root` inside the container. Use `sudo docker`, or adjust the socket's group in `postStartCommand`.

### Docker on Linux hosts

Linux hosts may use either the host socket (as above) or DinD:

```jsonc
{
  "privileged": true,
  "mounts": [
    "source=devcontainer-docker,target=/var/lib/docker,type=volume"
  ],
  "postStartCommand": "start-dockerd"
}
```

## GitHub Actions

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    container:
      image: quay.io/frithuz/devcontainer:<YYYYMMDD>@sha256:<digest>
      options: --user root
    steps:
      - uses: actions/checkout@<sha>
      - run: golangci-lint run
```

- `--user root` is required. GitHub mounts the workspace and runner tooling with ownership that a non-root container user can't write to.
- If git complains about "dubious ownership" after checkout, add `git config --global --add safe.directory "$GITHUB_WORKSPACE"`. The image doesn't set this globally, so it doesn't weaken local devcontainers.
- Every image-provided command is on the default `PATH`, so it works even though Actions ignores the image's `ENV PATH`. Tools you `go install` during a job need `$GOPATH/bin` added through `$GITHUB_PATH`.
- `BASH_ENV` applies to `run:` steps that use bash too. This is intentional: CI sees the same environment as sandboxes.
- JavaScript actions need Node on the runner side, and GitHub injects its own copy. The image's Node is for your steps.
- Actions sets `HOME=/github/home`. pnpm's configuration doesn't depend on `HOME`, because it's set through image `ENV` (see [pnpm configuration](architecture.md#pnpm-configuration)).
- Avoid `actions/setup-python`, `setup-node`, and `setup-go`. They install separate toolchains that drift from the image's pinned ones.

### Docker-in-Docker

Jobs that build or run containers start the image's own daemon:

```yaml
    container:
      image: quay.io/frithuz/devcontainer:<YYYYMMDD>@sha256:<digest>
      options: --user root --privileged --volume /var/lib/docker
    steps:
      - run: start-dockerd
      - run: docker buildx build .
```

- `--privileged` is required for `dockerd` to run.
- `--volume /var/lib/docker` gives the daemon an anonymous volume, because its storage can't sit on the container's overlay filesystem.
- GitHub-hosted runners are Linux, so the macOS restriction doesn't apply. Self-hosted runners on macOS must not use DinD.

## Agent sandboxes (`sbx`)

The image meets the [Docker Sandboxes custom image requirements](https://docs.docker.com/ai/sandboxes/customize/author/base-images/#use-your-own-linux-image) (see [architecture.md](architecture.md#docker-sandboxes-contract)). On its own it launches a bash shell. To run an agent, use a **kit** from `sandboxes/`. A kit is a thin Dockerfile that sets the agent as its entrypoint, plus a descriptor that declares capabilities.

`sandboxes/claude/claude.dockerfile`:

```dockerfile
FROM quay.io/frithuz/devcontainer:<YYYYMMDD>@sha256:<digest>
USER agent
ENTRYPOINT ["claude"]
CMD []
```

`sandboxes/claude/claude.yaml`:

```yaml
# syntax=docker/sandbox-kit:3
schemaVersion: "3"
kind: workload

capabilities:
  - type: com.docker.sandbox/sbx@1
  - type: com.docker.sandbox/network-policy@1
    config:
      runtime:
        allow:
          - api.anthropic.com
          # + auto-update and auth hosts (to be determined)
  - type: com.docker.sandbox/credential@1
    config:
      service: anthropic
      phase: runtime
      apiKey:
        name: ANTHROPIC_API_KEY
        proxyManaged: true
        inject:
          - domain: api.anthropic.com
            header: x-api-key
            format: "%s"
```

The Codex kit follows the same shape, with OpenAI hosts and credentials.

**Kits aren't published.** The only thing in the registry is the image itself (plus its source artifacts). `sbx` builds a kit from this repository at a pinned commit, using a git reference:

```sh
sbx run 'git+https://github.com/<owner>/devcontainer#ref=<COMMIT>&dir=sandboxes/claude' <workspace>
```

When working on a kit, use a local checkout: `sbx run ./sandboxes/claude <workspace>`. Each kit's Dockerfile pins the image by digest, so a given commit always builds the same sandbox.

- No credentials are in the image. The sandbox's credential proxy injects them at runtime.
- Agents may auto-update inside the sandbox. If they do, the network policy must allow their update hosts.
- **Deferred:** the full allowlist for each kit (API, auth, and auto-update hosts) will be defined once the kits are actually in use.
- Don't run `start-dockerd` inside a sandbox. Container access in a sandbox is up to `sbx`, and will be defined alongside the kits.
- `sbx` launches agents through non-interactive bash, so the environment comes from `ENV` and `BASH_ENV`, never from `.bashrc`.
