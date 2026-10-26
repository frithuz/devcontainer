# Usage

There is one image, built for `linux/amd64` and `linux/arm64`, with no per-context variants. Everything specific to a context lives in that context's configuration: `devcontainer.json`, the workflow's `container:` block, or a sandbox kit.

Reference a **scheduled snapshot by digest**, and let your own Dependabot keep it current:

```text
quay.io/frithuz/devcontainer:<YYYYMMDD>@sha256:<digest>
```

Tags are described in [maintenance.md](maintenance.md#publishing-publishyml).

### Which registry

The same image, with the same tags and digests, is published to Quay (`quay.io/frithuz/devcontainer`, the default) and GHCR (`ghcr.io/<owner>/devcontainer`). Use GHCR from GitHub Actions: pulls stay inside GitHub's network, so they're fast and free.

GHCR gets a new image first, and Quay follows as it's copied. Tests don't gate publication, so a pinned digest fixes the contents you consume but doesn't imply passing tests. If you need that, check the publish run's results for the digest.

## Editor devcontainers

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
- Agent credentials and config stay out of the image. Mount them, or log in inside the container. `~/.claude` can be mounted whole. **Don't mount a whole `~/.codex`**: it would hide Codex's installed binaries. Mount `auth.json` and `config.toml` individually ([tooling.md](tooling.md#agent-installers)).

Dependabot's `devcontainers` and `docker` ecosystems can bump the image reference.

### Docker on macOS hosts

**Never run Docker-in-Docker on a macOS host.** It causes corruption ([architecture.md](architecture.md#never-run-dind-on-macos-hosts)). Mount the host's socket instead, and don't run `start-dockerd`:

```jsonc
{
  "mounts": [
    "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"
  ]
}
```

Depending on the backend, the socket may be owned by `root` inside the container. Use `sudo docker`, or adjust the socket's group in `postStartCommand`.

### Docker on Linux hosts

Linux hosts can use the host socket (as above) or DinD:

```jsonc
{
  "privileged": true,
  "mounts": [
    "source=<unique-instance-id>-docker,target=/var/lib/docker,type=volume",
    "source=<unique-instance-id>-containerd,target=/var/lib/containerd,type=volume"
  ],
  "postStartCommand": "start-dockerd"
}
```

Each daemon needs exclusive use of its storage, so the volume names must be unique per devcontainer instance, across projects and worktrees too.

## GitHub Actions

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    defaults:
      run:
        shell: bash
    container:
      image: ghcr.io/<owner>/devcontainer:<YYYYMMDD>@sha256:<digest>
      options: --user root
    steps:
      - uses: actions/checkout@<sha>
      - run: golangci-lint run
```

- **`--user root` is required.** GitHub mounts the workspace and runner tooling with ownership a non-root user can't write to. If git then reports "dubious ownership", add `git config --global --add safe.directory "$GITHUB_WORKSPACE"`. The image doesn't set this globally, so local devcontainers keep the protection.
- **Set `shell: bash`.** Container jobs otherwise default to `sh`, which doesn't load `BASH_ENV`.
- Actions ignores the image's `ENV PATH`. Every image-provided command still resolves, but tools you `go install` need `$GOPATH/bin` added through `$GITHUB_PATH`.
- Actions sets `HOME=/github/home`. pnpm's configuration still applies, because it comes from image `ENV`.
- JavaScript actions run on the runner's own Node. The image's Node is for your steps.
- Avoid `actions/setup-python`, `setup-node`, and `setup-go`. They install separate toolchains that drift from the image's.

### Docker in CI

Ordinary container jobs use the runner's daemon, through the socket the standard runner mounts. The image provides the CLI, and the runner determines the server version. Don't run `start-dockerd` there. Custom runner backends have to supply equivalent daemon access.

## Agent sandboxes (`sbx`)

> Planned: the kits under `sandboxes/` don't exist yet.

The image meets the [Docker Sandboxes custom image requirements](https://docs.docker.com/ai/sandboxes/customize/author/base-images/#use-your-own-linux-image) ([architecture.md](architecture.md#docker-sandboxes-contract)). On its own it starts a bash shell. To run an agent, use a **kit**: a thin Dockerfile that pins the image by digest and sets the agent as `ENTRYPOINT`, plus a descriptor declaring the `sbx`, network-policy, and credential capabilities.

**Kits aren't published.** `sbx` builds them from this repository at a pinned commit, so a given commit always builds the same sandbox:

```sh
sbx run 'git+https://github.com/<owner>/devcontainer#ref=<COMMIT>&dir=sandboxes/claude' <workspace>
```

When working on a kit, run it from a local checkout: `sbx run ./sandboxes/claude <workspace>`.

- No credentials are in the image. The sandbox's credential proxy injects them at runtime.
- Agents may auto-update inside the sandbox, so the network policy must allow their update hosts. The full allowlist for each kit is deferred until the kits are in use.
- Don't run `start-dockerd` inside a sandbox. Container access there is up to `sbx`.
