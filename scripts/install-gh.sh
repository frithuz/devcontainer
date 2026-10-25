#!/usr/bin/env bash
# Download the latest GitHub CLI release for TARGETARCH and verify it against the
# release's published checksums file. Writes the binary, LICENSE, VERSION, and SOURCE
# (release URL and tarball SHA-256, for /legal/manifest.tsv) to $1.
set -euo pipefail

readonly out=${1:?usage: install-gh.sh <output-dir>}
readonly repo=https://github.com/cli/cli

case "${TARGETARCH:?TARGETARCH must be set}" in
amd64 | arm64) arch=$TARGETARCH ;;
*)
	echo "install-gh: unsupported architecture: $TARGETARCH" >&2
	exit 1
	;;
esac

# Resolve the latest release from the redirect instead of the API, which is rate limited.
latest_url=$(curl -fsSLI --retry 3 -o /dev/null -w '%{url_effective}' "$repo/releases/latest")
tag=${latest_url##*/}
if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "install-gh: unexpected latest release URL: $latest_url" >&2
	exit 1
fi
version=${tag#v}

name="gh_${version}_linux_${arch}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

curl -fsSL --retry 3 -O "$repo/releases/download/$tag/$name.tar.gz"
curl -fsSL --retry 3 -O "$repo/releases/download/$tag/gh_${version}_checksums.txt"
grep -E "  $name\.tar\.gz\$" "gh_${version}_checksums.txt" | sha256sum -c -

tar -xzf "$name.tar.gz"
mkdir -p "$out"
install -m 0755 "$name/bin/gh" "$out/gh"
install -m 0644 "$name/LICENSE" "$out/LICENSE"
printf '%s\n' "$version" >"$out/VERSION"
printf '%s sha256:%s\n' "$repo/releases/download/$tag/$name.tar.gz" "$(sha256sum "$name.tar.gz" | cut -d' ' -f1)" >"$out/SOURCE"
"$out/gh" --version
