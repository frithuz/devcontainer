#!/usr/bin/env bash
# Codex's legal record for the kit (codex.dockerfile's legal stage), into /out/legal. Docker's
# mixin ships no notices, so this takes Codex's LICENSE and NOTICE from its release tag, and the
# license texts of the ripgrep it bundles from ripgrep's tag, at the version Codex's package
# manifest for rg pins. Writes the image's manifest (/mnt/manifest.tsv) with both rows added. The
# package's bwrap is the image's own, recorded as Debian's bubblewrap package already.
set -euo pipefail

version=$(jq -er .version /mnt/codex/codex-package.json)
target=$(jq -er .target /mnt/codex/codex-package.json)
if [[ ! $MIXIN =~ :([0-9]+\.[0-9]+\.[0-9]+)@ ]]; then
	echo "MIXIN has no version tag: $MIXIN" >&2
	exit 1
fi
if [[ $version != "${BASH_REMATCH[1]}" ]]; then
	echo "the mixin's package is Codex $version, not the pinned ${BASH_REMATCH[1]}" >&2
	exit 1
fi
arch=$TARGETARCH
tag=rust-v$version

if grep -q $'^codex\t' /mnt/manifest.tsv; then
	echo 'the image already records Codex; pin an image without agents' >&2
	exit 1
fi

# Files from <repo> at <ref> into /legal/attribution/<component> (staged under /out), with a
# SOURCE record of where each came from, as scripts/collect-legal.sh records them. Sets notices
# to the notices' paths in the kit.
fetch() {
	local component=$1 repo=$2 ref=$3 license=$4 dir path file
	shift 4
	dir=/out/legal/attribution/$component
	mkdir -p "$dir"
	notices=()
	{
		printf 'component: %s\nrepository: https://github.com/%s\nref: %s\nlicense: %s\nfiles:\n' \
			"$component" "$repo" "$ref" "$license"
		for path in "$@"; do
			file=$dir/${path##*/}
			curl -fsSL --retry 3 -o "$file" "https://raw.githubusercontent.com/$repo/$ref/$path"
			printf '  - path: %s\n    url: https://github.com/%s/blob/%s/%s\n    sha256: %s\n' \
				"$path" "$repo" "$ref" "$path" "$(sha256sum "$file" | cut -d' ' -f1)"
			notices+=("/legal/attribution/$component/${path##*/}")
		done
	} >"$dir/SOURCE"
}

fetch codex openai/codex "$tag" Apache-2.0 LICENSE NOTICE
codex_notices=${notices[*]}
codex_sha=$(sha256sum /mnt/codex/codex | cut -d' ' -f1)

# Codex's package takes rg from a DotSlash manifest that names the ripgrep release per platform.
case $arch in
amd64) rg_platform=linux-x86_64 ;;
arm64) rg_platform=linux-aarch64 ;;
*)
	echo "unsupported TARGETARCH: $arch" >&2
	exit 1
	;;
esac
dotslash=$(curl -fsSL --retry 3 "https://raw.githubusercontent.com/openai/codex/$tag/scripts/codex_package/rg")
rg_path=$(grep -v '^#!' <<<"$dotslash" | jq -er --arg platform "$rg_platform" '.platforms[$platform].path')
if [[ ! $rg_path =~ ^ripgrep-([0-9.]+)- ]]; then
	echo "unexpected ripgrep path in Codex's rg manifest: $rg_path" >&2
	exit 1
fi
rg_version=${BASH_REMATCH[1]}
fetch ripgrep BurntSushi/ripgrep "$rg_version" 'Unlicense OR MIT' COPYING LICENSE-MIT UNLICENSE
rg_notices=${notices[*]}

release=https://github.com/openai/codex/releases/tag/$tag
{
	cat /mnt/manifest.tsv
	printf '%s\t' codex "$version" "$arch" Apache-2.0 "$codex_notices"
	printf '%s\n' "mixin:$MIXIN release:$release target:$target binary-sha256:$codex_sha paths: /opt/codex /usr/local/bin/codex"
	printf '%s\t' ripgrep "$rg_version" "$arch" 'Unlicense OR MIT' "$rg_notices"
	printf '%s\n' "embedded-in:codex source:https://github.com/BurntSushi/ripgrep/tree/$rg_version paths: /opt/codex/codex-path/rg"
} >/out/legal/manifest.tsv
echo "legal: codex $version $target, ripgrep $rg_version"
