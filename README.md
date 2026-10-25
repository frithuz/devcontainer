# devcontainer

A single Ubuntu 26.04 LTS container image, `quay.io/frithuz/devcontainer` (mirrored to `ghcr.io/<owner>/devcontainer` for GitHub Actions), that gives every place work happens the same platform and the same toolset:

1. **Editor devcontainers.** Isolated development in any client that supports the [Dev Container spec](https://containers.dev).
2. **GitHub Actions CI.** Jobs run inside the image, so CI uses the same tools developers do.
3. **Agent sandboxes.** Coding agents run inside the image through [Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/).

> **Status: draft.** This README and `docs/` describe how the repository *will* work. Nothing is built yet.

## Principles

- **Copy, don't install.** Tools come from pinned upstream images wherever possible. ([tooling](docs/tooling.md))
- **Pin the platform, not the agents.** Platform tools are pinned. Claude Code and Codex are only guaranteed to be present, and may self-update. ([tooling](docs/tooling.md#agent-installers))
- **Default `PATH` only.** Every command resolves without relying on `ENV PATH`. ([architecture](docs/architecture.md#default-path))
- **Automate updates.** Dependabot covers what it can, and everything else is listed explicitly. ([maintenance](docs/maintenance.md))
- **One multi-arch image, three contexts.** Context-specific behavior lives in the consumer's configuration, not in the image. ([usage](docs/usage.md))

## Documentation

| Document | Covers |
| --- | --- |
| [`docs/tooling.md`](docs/tooling.md) | What's in the image, where each tool comes from, how it's updated |
| [`docs/architecture.md`](docs/architecture.md) | Repo layout, build stages, users, environment, `sbx` contract |
| [`docs/usage.md`](docs/usage.md) | Consuming the image as a devcontainer, in CI, and in sandboxes |
| [`docs/maintenance.md`](docs/maintenance.md) | Dependabot, CI, releases, contributor expectations |
| [`docs/legal.md`](docs/legal.md) | License and attribution files shipped in `/legal` |
| [`docs/integrations/`](docs/integrations/) | Setup for external services: [Quay.io](docs/integrations/quayio.md), [GHCR mirror](docs/integrations/ghcr.md), [1Password](docs/integrations/1password.md) |
