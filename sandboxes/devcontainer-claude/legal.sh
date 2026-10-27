#!/usr/bin/env bash
# Claude Code's legal record for the kit (claude.dockerfile's legal stage), into /out/legal. Docker's
# mixin ships no notices, so this verifies the target's binary (/mnt/claude) against Anthropic's
# release manifest for the version the mixin is pinned to, takes Anthropic's notice (LICENSE.md)
# from the npm package of the same version, checked against its integrity, and writes the image's
# manifest (/mnt/manifest.tsv) with Claude Code's row added.
set -euo pipefail

if [[ ! $MIXIN =~ :([0-9]+\.[0-9]+\.[0-9]+)@ ]]; then
	echo "MIXIN has no version tag: $MIXIN" >&2
	exit 1
fi
version=${BASH_REMATCH[1]}
arch=$TARGETARCH
case $arch in
amd64) platform=linux-x64 ;;
arm64) platform=linux-arm64 ;;
*)
	echo "unsupported TARGETARCH: $arch" >&2
	exit 1
	;;
esac

if grep -q $'^claude\t' /mnt/manifest.tsv; then
	echo 'the image already records Claude Code; pin an image without agents' >&2
	exit 1
fi

work=$(mktemp -d)
release=https://downloads.claude.ai/claude-code-releases/$version/manifest.json
curl -fsSL --retry 3 -o "$work/release.json" "$release"
binary_sha=$(sha256sum /mnt/claude | cut -d' ' -f1)
expected=$(jq -er --arg platform "$platform" '.platforms[$platform].checksum' "$work/release.json")
commit=$(jq -er .commit "$work/release.json")
if [[ $binary_sha != "$expected" ]]; then
	echo "claude $version $platform sha256 $binary_sha doesn't match $release ($expected)" >&2
	exit 1
fi

curl -fsSL --retry 3 -o "$work/npm.json" "https://registry.npmjs.org/@anthropic-ai/claude-code/$version"
tarball=$(jq -er .dist.tarball "$work/npm.json")
integrity=$(jq -er .dist.integrity "$work/npm.json")
curl -fsSL --retry 3 -o "$work/package.tgz" "$tarball"
if [[ sha512-$(openssl dgst -sha512 -binary "$work/package.tgz" | base64 -w0) != "$integrity" ]]; then
	echo "claude's npm package doesn't match its registry integrity $integrity" >&2
	exit 1
fi
tar -xzf "$work/package.tgz" -C "$work" package/LICENSE.md

readonly attribution=/out/legal/attribution/claude
mkdir -p "$attribution"
cp "$work/package/LICENSE.md" "$attribution/LICENSE.md"
cat >"$attribution/SOURCE" <<SOURCE
component: claude
repository: none (proprietary)
ref: $version (commit $commit)
license: LicenseRef-Anthropic-Terms
files:
  - path: package/LICENSE.md
    url: $tarball
    integrity: $integrity
    sha256: $(sha256sum "$attribution/LICENSE.md" | cut -d' ' -f1)
SOURCE

{
	cat /mnt/manifest.tsv
	printf '%s\t' claude "$version" "$arch" LicenseRef-Anthropic-Terms /legal/attribution/claude/LICENSE.md
	printf '%s\n' "mixin:$MIXIN release:$release commit:$commit binary-sha256:$binary_sha paths: /usr/local/bin/claude"
} >/out/legal/manifest.tsv
echo "legal: claude $version $platform, binary sha256 $binary_sha"
