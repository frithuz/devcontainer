#!/usr/bin/env bash
# Copy /legal/manifest.tsv out of a registry image, as one <os>_<arch>/manifest.tsv per platform
# under <dest>. Runs on the host, including macOS's bash 3.2.
#
#   scripts/copy-manifests.sh <image> <dest> [<platforms>]
#
# <platforms> is comma-separated, linux/amd64,linux/arm64 by default. <dest> must not exist yet,
# or be empty, so no stale manifest survives. COPY --from doesn't run anything, so no platform
# needs emulation, and platform-split keeps the <os>_<arch>/ directory even for one platform.
set -euo pipefail

image=${1:?usage: scripts/copy-manifests.sh <image> <dest> [<platforms>]}
dest=${2:?usage: scripts/copy-manifests.sh <image> <dest> [<platforms>]}
platforms=${3:-linux/amd64,linux/arm64}

if [[ -e $dest && -n $(ls -A "$dest") ]]; then
	echo "copy-manifests: $dest isn't empty" >&2
	exit 1
fi

docker buildx build --quiet --platform "$platforms" \
	--output "type=local,platform-split=true,dest=$dest" - >/dev/null <<EOF
FROM scratch
COPY --from=$image /legal/manifest.tsv /
EOF
