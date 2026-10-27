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
- The image carries no agent CLIs; the [sandbox kits](#agent-sandboxes-sbx) add them. In a devcontainer, install one with its vendor's installer.

Dependabot's `devcontainers` and `docker` ecosystems can bump the image reference.

### Docker

Use the host's daemon through its socket, or run Docker-in-Docker. To use the host's daemon, mount its socket and don't run `start-dockerd`:

```jsonc
{
  "mounts": [
    "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"
  ]
}
```

Depending on the backend, the socket may be owned by `root` inside the container. Use `sudo docker`, or adjust the socket's group in `postStartCommand`.

For DinD, run the container privileged with its own volumes for the daemon's data:

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
    steps:
      - uses: actions/checkout@<sha>
      - run: go test ./...
```

- Steps run as root, the image's default user, as [GitHub requires](https://docs.github.com/en/actions/reference/workflows-and-actions/dockerfile-support#user): it mounts the workspace and runner tooling with ownership a non-root user can't write to. Don't pass `--user agent`. If git reports "dubious ownership", add `git config --global --add safe.directory "$GITHUB_WORKSPACE"`. The image doesn't set this globally, so local devcontainers keep the protection.
- **Set `shell: bash`.** Container jobs otherwise default to `sh`, which doesn't load `BASH_ENV`.
- Steps keep the image's `ENV`, `PATH` included, so tools you `go install` resolve from `$GOPATH/bin`. Actions only sets `HOME=/github/home`, which pnpm's configuration doesn't depend on.
- JavaScript actions run on the runner's own Node. The image's Node is for your steps.
- Avoid `actions/setup-python`, `setup-node`, and `setup-go`. They install separate toolchains that drift from the image's.

### Docker in CI

Ordinary container jobs use the runner's daemon, through the socket the standard runner mounts. The image provides the CLI, and the runner determines the server version. Don't run `start-dockerd` there. Custom runner backends have to supply equivalent daemon access.

## Agent sandboxes (`sbx`)

The image meets the [Docker Sandboxes custom image requirements](https://docs.docker.com/ai/sandboxes/customize/author/base-images/#use-your-own-linux-image) ([architecture.md](architecture.md#docker-sandboxes-contract)). On its own it starts a bash shell (`agent`'s login shell is nu, but the `CMD` is bash). To run an agent, use a **kit** under `sandboxes/`: `devcontainer-claude` or `devcontainer-codex`. Each is a [v3 workload](https://docs.docker.com/ai/sandboxes/customize/) made of two files:

- `<agent>.dockerfile` pins the image and Docker's mixin for the agent by digest, copies the agent onto the image, sets it as `ENTRYPOINT`, and labels the image `com.docker.sandboxes.start-docker`, without which `sbx` doesn't give the image's Docker engine the privileges it needs to start. Its `legal.nu` adds the agent's notices.
- `<agent>.yaml` is the descriptor. Its `provides` states the agent version the pinned mixin carries. It declares the `sbx`, network-policy, credential, volume, and lifecycle capabilities, and seeds the agent's config from the credential mode the host binds.

V3 needs `sbx` v0.45 or later, and v3 workloads only take v3 mixins. `sbx` names a kit's agent after its directory and rejects a built-in agent's name, so the directories are `devcontainer-<agent>`, not `<agent>`. A publish run keeps the pins current through a PR ([maintenance.md](maintenance.md#sandbox-kits)).

**Each kit is published to its own repository**, `quay.io/frithuz/claude-kit` and `quay.io/frithuz/codex-kit`, mirrored to `ghcr.io/<owner>/claude-kit` and `ghcr.io/<owner>/codex-kit` ([maintenance.md](maintenance.md#publishing-the-kits)). Pin one by digest. `sbx` names a published kit's agent after its repository. Remote kit sources default to Docker Hub only, so allow the repositories once:

```sh
sbx settings set kit.allowedSources '["docker.io/","quay.io/frithuz/claude-kit","quay.io/frithuz/codex-kit"]'
sbx run 'quay.io/frithuz/claude-kit:latest@sha256:<digest>' <workspace>
```

`kit.allowedSources` replaces the whole list, so keep any sources you already allow. A published kit carries its image's layers, so it carries the image's copyleft source the same way ([legal.md](legal.md#publishing)).

`sbx` can also build a kit from this repository at any commit, including ones that were never published. Allow `github.com/frithuz/devcontainer`, then run `sbx run 'git+https://github.com/frithuz/devcontainer.git#ref=<COMMIT>&dir=sandboxes/devcontainer-claude' <workspace>`. When working on a kit, run it from a local checkout: `sbx run ./sandboxes/devcontainer-claude <workspace>`. To build one without `sbx`, use the kit frontend directly: `docker buildx build -f sandboxes/devcontainer-claude/claude.yaml sandboxes/devcontainer-claude`.

- Pass `--kit-arg model=<id>` or `--kit-arg reasoningEffort=<level>` to set the agent's defaults. Both are empty by default, which keeps the CLI's own default.
- No credentials are in the image. The sandbox's credential proxy injects them at runtime, as an API key or OAuth, whichever the host has bound.
- git over SSH to GitHub uses the host's SSH agent. Load your key with `ssh-add` and keep `sbx`'s `ssh.agentForwardingEnabled` on, the default. Each kit asks for the agent only to log in as `git@github.com`, so it can't log in anywhere else. Without an agent, the sandbox still starts, without SSH. As Docker's `sbx/github-ssh` mixin does, the kits install GitHub's SSH host keys when the sandbox is created, in `/etc/ssh/ssh_known_hosts`.
- git signs commits and tags with the host's SSH key, as Docker's `git-ssh-sign` kit does, in repositories that have a remote. Those without one, such as test fixtures, don't sign. The agent may only make git signatures. When the repository's remote is on github.com and `gh` is authenticated, the key command picks an agent key registered as a signing key on the committer's GitHub account. The kit includes the whole signing setup only when the host forwards an SSH agent. Each kit's dockerfile adds the key command, unmodified, from Docker's kit repository at a pinned commit and checksum, so building a kit needs `raw.githubusercontent.com`.
- Agents may auto-update inside the sandbox, so each kit allows its agent's update hosts, along with the image's apt sources and the npm, PyPI, and Go module registries.
- Each agent comes from Docker's mixin for it, at the version the kit pins, and doesn't update itself ([tooling.md](tooling.md#agents)). Codex comes without its voice libraries, which need audio devices a sandbox doesn't have.
- Claude Code's session state lives on sandbox volumes. Codex's app server copies its package into `~/.codex`, so nothing is mounted there.
