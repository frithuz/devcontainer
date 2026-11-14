#!/usr/bin/env bash
# Downloads the latest release binary of each GitHub CLI extension in EXTENSIONS (owner/name,
# space-separated) for TARGETARCH to /opt/gh-extensions/<name>/ (Dockerfile's gh-extensions stage),
# with the LICENSE at the release's tag and a SOURCE record for scripts/collect-legal.sh (install:
# release). Their releases publish no checksums, so each binary is checked against the SHA-256
# GitHub reports for the asset. A repository in IMMUTABLE must have an immutable latest release,
# whose tag and assets can't change once published; for the others, the digest only catches a
# corrupt download.
set -euo pipefail

case ${TARGETARCH:?TARGETARCH must be set} in
amd64 | arm64) ;;
*)
	echo "gh-extensions: unsupported architecture: $TARGETARCH" >&2
	exit 1
	;;
esac
read -ra extensions <<<"${EXTENSIONS:?EXTENSIONS must be set}"
read -ra immutable <<<"${IMMUTABLE:-}"
readonly asset=linux-$TARGETARCH
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for repo in "${extensions[@]}"; do
	name=${repo#*/}
	# One unauthenticated API request per extension (60 an hour per address): the latest
	# release's tag, whether it's immutable, and its assets' digests.
	if ! curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' -o "$work/release.json" \
		"https://api.github.com/repos/$repo/releases/latest"; then
		echo "gh-extensions: $repo: couldn't read its latest release from the GitHub API (rate limited?)" >&2
		exit 1
	fi
	tag=$(jq -r '.tag_name' "$work/release.json")
	if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "gh-extensions: $repo: unexpected latest release tag: '$tag'" >&2
		exit 1
	fi
	is_immutable=$(jq -r '.immutable == true' "$work/release.json")
	if [[ " ${immutable[*]} " == *" $repo "* && $is_immutable != true ]]; then
		echo "gh-extensions: $repo: release $tag isn't immutable" >&2
		exit 1
	fi
	digest=$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' "$work/release.json")
	if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
		echo "gh-extensions: $repo: release $tag has no SHA-256 for $asset: '$digest'" >&2
		exit 1
	fi

	url=https://github.com/$repo/releases/download/$tag/$asset
	curl -fsSL --retry 3 -o "$work/$asset" "$url"
	sha256=$(sha256sum "$work/$asset" | cut -d' ' -f1)
	if [[ $sha256 != "${digest#sha256:}" ]]; then
		echo "gh-extensions: $url has sha256 $sha256, but GitHub reports ${digest#sha256:}" >&2
		exit 1
	fi
	license_url=https://raw.githubusercontent.com/$repo/$tag/LICENSE
	out=/opt/gh-extensions/$name
	mkdir -p "$out"
	install -m 0755 "$work/$asset" "$out/$name"
	curl -fsSL --retry 3 -o "$out/LICENSE" "$license_url"
	cat >"$out/SOURCE" <<SOURCE
component: $name
repository: https://github.com/$repo
ref: $tag
immutable: $is_immutable
release: $url
sha256: $sha256
license: $license_url
license-sha256: $(sha256sum "$out/LICENSE" | cut -d' ' -f1)
SOURCE
	"$out/$name" --version
done
