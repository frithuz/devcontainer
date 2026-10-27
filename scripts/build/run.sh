#!/usr/bin/env bash
# Runs a Dockerfile step's scripts in order, stopping at the first that fails. Each is printed to
# the build log between a header, which carries its sha256, and a footer, so the log shows exactly
# what ran without the image's history recording it. Scripts are mounted under /mnt/src at their
# repository paths.
set -euo pipefail

rule=$(printf '%.0s-' {1..72})
for script in "$@"; do
	name=${script#/mnt/src/}
	printf '%s\nScript filename: %s\nsha256: %s\n%s\n' \
		"$rule" "$name" "$(sha256sum "$script" | cut -d' ' -f1)" "$rule"
	cat "$script"
	printf '%s\nEnd of script: %s\n%s\n' "$rule" "$name" "$rule"
	bash "$script"
done
