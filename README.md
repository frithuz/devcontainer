# devcontainer

A single container image on Docker Hardened Images' Debian 13 base, `quay.io/frithuz/devcontainer` (mirrored to `ghcr.io/<owner>/devcontainer` for GitHub Actions), that gives every place work happens the same platform and the same toolset:

1. **Editor devcontainers.** Isolated development in any client that supports the [Dev Container spec](https://containers.dev).
2. **GitHub Actions CI.** Jobs run inside the image, so CI uses the same tools developers do.
3. **Agent sandboxes.** Coding agents run inside the image through [Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/).

> **Status: in progress.** The image is published, and the Claude Code and Codex sandbox kits build from this repository. PR CI runs the linters, the smoke tests, the DinD checks, and source planning. Parts of publishing are still designs; the docs mark those parts as planned.

## Principles

- **Copy, don't install.** Tools come from pinned upstream images wherever possible. ([tooling](docs/tooling.md))
- **One image for CI and sandboxes.** The image carries the platform tools, and no agents. The sandbox kits add Claude Code or Codex from Docker's agent mixins, pinned by version. ([tooling](docs/tooling.md#agents))
- **Default `PATH` only.** Every command resolves without relying on `ENV PATH`. ([architecture](docs/architecture.md#default-path))
- **Automate updates.** Dependabot covers what it can, and everything else is listed explicitly. ([maintenance](docs/maintenance.md))
- **Build once, publish to both registries.** Weekly builds refresh unpinned installations. Tests report against the published digest while Quay synchronization proceeds; test failures do not remove releases. ([publishing](docs/maintenance.md#workflow))
- **Tools arrive preinstalled.** Publish their required source and notices alongside the image, including coverage for base-image and apt packages. ([legal](docs/legal.md))
- **One multi-arch image, three contexts.** Context-specific behavior lives in the consumer's configuration, not in the image. ([usage](docs/usage.md))

## Documentation

When working on this repository, run `task repo:init` after cloning to activate
the Git hooks. See [contributor setup](docs/maintenance.md#contributor-setup)
for prerequisites and hook behavior.

| Document | Covers |
| --- | --- |
| [`docs/tooling.md`](docs/tooling.md) | How tools are chosen and installed, and per-tool quirks |
| [`docs/architecture.md`](docs/architecture.md) | Build structure, `PATH`, shared directories, users, Docker, environment, `sbx` contract |
| [`docs/usage.md`](docs/usage.md) | Consuming the image as a devcontainer, in CI, and in sandboxes |
| [`docs/maintenance.md`](docs/maintenance.md) | Dependabot, CI, releases, contributor expectations |
| [`docs/legal.md`](docs/legal.md) | Project license, third-party notices, and copyleft source publication |
| [`docs/data-model.md`](docs/data-model.md) | Draft design of inventories and registry-backed publication records |
| [`docs/integrations/`](docs/integrations/) | Setup for external services: [Quay.io](docs/integrations/quayio.md), [GHCR mirror](docs/integrations/ghcr.md), [registry.frithuz.dev (pnpr)](docs/integrations/registry-frithuz.md), [1Password](docs/integrations/1password.md) |

## License

This project's own code, configuration, and documentation are dedicated to the public domain under [Creative Commons Zero v1.0 Universal (CC0-1.0)](LICENSE), to the extent permitted by law, without warranty.

Third-party material and software redistributed in the container image retain their own licenses and terms. See [license scope and impacts](docs/legal.md#project-license) for details.
