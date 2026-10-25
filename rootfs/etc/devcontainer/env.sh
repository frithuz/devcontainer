# shellcheck shell=bash
# Environment for non-interactive bash (BASH_ENV). Sourced by every bash script,
# so it must stay idempotent and print nothing. Values that hold in every
# context belong in the Dockerfile's ENV; only shell logic goes here.

if [[ -n "${__DEVCONTAINER_ENV_SH:-}" ]]; then
	return 0
fi
__DEVCONTAINER_ENV_SH=1
