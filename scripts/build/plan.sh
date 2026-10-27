#!/usr/bin/env bash
# Resolves every root program's exact inputs from the manifests (source.Dockerfile's plan-run).
set -euo pipefail

mapfile -t manifests < <(find /mnt/manifests -name manifest.tsv | sort)
reuse_args=()
if [[ -n ${SOURCE_REUSE:-} ]]; then
	reuse_args=(--reuse "$SOURCE_REUSE")
fi
bash /mnt/scripts/plan-sources.sh --config /mnt/config --out /out "${reuse_args[@]}" "${manifests[@]}"
