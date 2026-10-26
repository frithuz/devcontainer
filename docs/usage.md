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

The image meets the [Docker Sandboxes custom image requirements](https://docs.docker.com/ai/sandboxes/customize/author/base-images/#use-your-own-linux-image) ([architecture.md](architecture.md#docker-sandboxes-contract)). On its own it starts a bash shell (`agent`'s login shell is nu, but the `CMD` is bash). To run an agent, use a **kit** under `sandboxes/`: `claude` or `codex`. Each is a [v3 workload](https://docs.docker.com/ai/sandboxes/customize/) made of two files:

- `<agent>.dockerfile` pins the image by digest and sets the agent as `ENTRYPOINT`.
- `<agent>.yaml` is the descriptor. Its `provides` states the agent version the pinned image installed. It declares the `sbx`, network-policy, credential, volume, and lifecycle capabilities, and seeds the agent's config from the credential mode the host binds.

V3 needs `sbx` v0.45 or later, and v3 workloads only take v3 mixins. A publish run keeps the pins current through a PR ([maintenance.md](maintenance.md#sandbox-kits)).

**Kits aren't published.** `sbx` builds them from this repository at a pinned commit, so a given commit always builds the same sandbox. Remote kit sources default to Docker Hub only, so allow this repository once:

```sh
sbx settings set kit.allowedSources '["docker.io/","github.com/frithuz/devcontainer"]'
sbx run 'git+https://github.com/frithuz/devcontainer.git#ref=<COMMIT>&dir=sandboxes/claude' <workspace>
```

`kit.allowedSources` replaces the whole list, so keep any sources you already allow. When working on a kit, run it from a local checkout: `sbx run ./sandboxes/claude <workspace>`. To build one without `sbx`, use the kit frontend directly: `docker buildx build -f sandboxes/claude/claude.yaml sandboxes/claude`.

- Pass `--kit-arg model=<id>` or `--kit-arg reasoningEffort=<level>` to set the agent's defaults. Both are empty by default, which keeps the CLI's own default.
- No credentials are in the image. The sandbox's credential proxy injects them at runtime, as an API key or OAuth, whichever the host has bound.
- Agents may auto-update inside the sandbox, so each kit allows its agent's update hosts, along with the image's apt sources and the npm, PyPI, and Go module registries.
- Claude Code's session state lives on sandbox volumes. Codex keeps its binaries in `~/.codex`, so nothing is mounted there.
- Don't run `start-dockerd` inside a sandbox. Container access there is up to `sbx`.
