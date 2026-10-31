#!/usr/bin/env bash
# Decide whether a build would materially change the published image
# (docs/maintenance.md#material-changes). Runs on the host, including macOS's bash 3.2.
#
#   scripts/image-changes.sh inputs <image>@sha256:<digest>
#   scripts/image-changes.sh inventory <image>@sha256:<digest> <manifests>
#
# inputs     prints true when the build inputs differ between HEAD and the commit the image was
#            built from (its index's org.opencontainers.image.revision), and false otherwise.
# inventory  prints true when any platform's manifest.tsv under <manifests> (<os>_<arch>/, as a
#            platform-split local export writes them) differs from the image's
#            /legal/manifest.tsv, ignoring the project row's revision, and false otherwise.
#
# Both print what differs to stderr. A lookup that fails is an error, never a change.
set -euo pipefail

# Relative to the caller, before the cd below.
if [[ ${1:-} == inventory && -n ${3:-} ]]; then
	manifests=$(cd "$3" && pwd)
fi
cd "$(dirname "$0")/.."

# What reaches the image: everything .dockerignore admits to the build context, plus the build
# definitions and the workflow that sets the image's annotations. The scripts that only compare,
# copy, or point the kits at images are left out, and so are the tests, which never reach the
# image.
inputs=(.dockerignore docker-bake.hcl .github/workflows/publish.yml)
while IFS= read -r line; do
	[[ $line == '!'* ]] || continue
	line=${line#!}
	inputs+=("${line%/}")
done <.dockerignore
inputs+=(
	':(exclude)scripts/copy-manifests.sh' ':(exclude)scripts/image-changes.sh'
	':(exclude)scripts/update-kits.sh' ':(exclude)test/'
	# Git compilation has its own release workflow; the main Dockerfile pins the artifact.
	':(exclude)scripts/build/git.sh' ':(exclude)scripts/build/git-artifact.sh'
	':(exclude)scripts/git-image-changes.sh'
)

usage() {
	echo "usage: scripts/image-changes.sh inputs <image>@sha256:<digest>" >&2
	echo "       scripts/image-changes.sh inventory <image>@sha256:<digest> <manifests>" >&2
	exit 2
}

mode=${1:-}
image=${2:-}
[[ $image =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || usage

case $mode in
inputs)
	(($# == 2)) || usage
	revision=$(docker buildx imagetools inspect "$image" --raw |
		jq -er '.annotations["org.opencontainers.image.revision"]')
	if ! git cat-file -e "$revision^{commit}" 2>/dev/null; then
		echo "image-changes: $image was built from $revision, which isn't in this clone" >&2
		echo true
		exit 0
	fi
	status=0
	git diff --quiet "$revision" HEAD -- "${inputs[@]}" || status=$?
	case $status in
	0)
		echo "image-changes: no build inputs changed since $revision" >&2
		echo false
		;;
	1)
		echo "image-changes: build inputs changed since $revision:" >&2
		git diff --stat "$revision" HEAD -- "${inputs[@]}" >&2
		echo true
		;;
	*) exit "$status" ;;
	esac
	;;
inventory)
	(($# == 3)) || usage
	platforms=
	for file in "$manifests"/*/manifest.tsv; do
		[[ -f $file ]] || {
			echo "image-changes: no <os>_<arch>/manifest.tsv under $manifests" >&2
			exit 1
		}
		dir=${file%/manifest.tsv}
		dir=${dir##*/}
		platforms+=${platforms:+,}${dir/_//}
	done

	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT
	scripts/copy-manifests.sh "$image" "$work/published" "$platforms"

	# The project row's version is the commit that built the image. Its files are build inputs.
	normalize() {
		awk -F'\t' -v OFS='\t' '$1 == "devcontainer" { $2 = "-" } { print }' "$1" | sort
	}
	changed=false
	for file in "$manifests"/*/manifest.tsv; do
		dir=${file%/manifest.tsv}
		dir=${dir##*/}
		# normalize runs in a process substitution, which would hide a missing file as a change.
		[[ -f $work/published/$dir/manifest.tsv ]] || {
			echo "image-changes: $image has no $dir manifest.tsv" >&2
			exit 1
		}
		if ! diff <(normalize "$work/published/$dir/manifest.tsv") <(normalize "$file") >"$work/$dir.diff"; then
			echo "image-changes: $dir inventory changed (< published, > built):" >&2
			grep '^[<>]' "$work/$dir.diff" >&2
			changed=true
		fi
	done
	[[ $changed == true ]] || echo "image-changes: no inventory changes on $platforms" >&2
	echo "$changed"
	;;
*) usage ;;
esac
