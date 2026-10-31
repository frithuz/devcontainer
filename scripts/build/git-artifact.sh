#!/usr/bin/env bash
# Finalize the standalone artifact only; the main image's build stays unchanged.
set -euo pipefail

legal=/out/legal/attribution/git
actual=$(awk '$1 == "sha256:" { print $2 }' "$legal/SOURCE")
if [[ $actual != "${SHA256:?}" ]]; then
	echo "Git source checksum $actual does not match $SHA256" >&2
	exit 1
fi
# git.sh authenticates the source before compiling. Check the separately pinned archive
# checksum before publishing, and preserve the exact recipe independently of later builds.
mkdir -p "$legal/build/scripts/build"
cp /mnt/src/Dockerfile.git "$legal/build/"
cp /mnt/src/scripts/build/{run,apt-bootstrap,git,git-artifact}.sh "$legal/build/scripts/build/"
printf 'revision: %s\nrepository: %s\n' "${REVISION:-local}" "${REPOSITORY_URL:-local}" >"$legal/build/ORIGIN"

git=/out/usr/local/bin/git
[[ $("$git" --version) == "git version ${VERSION:?}" ]]
for helper in "$git" /out/usr/local/libexec/git-core/git-remote-http; do
	dependencies=$(ldd "$helper")
	if [[ $dependencies == *'not found'* ]]; then
		echo "$helper has unresolved libraries: $dependencies" >&2
		exit 1
	fi
done
