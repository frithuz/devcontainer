#!/usr/bin/env bash
# Plan and build the source images for an image's manifests (docs/legal.md#source-images).
# Runs on the host, including macOS's bash 3.2: the planning and fetching happen in BuildKit.
#
#   scripts/build-sources.sh [--from-image <image>] [--plan-only] [--only <root>]... [-- <bake args>]
#
#   --from-image  copy /legal/manifest.tsv out of a local image into $MANIFESTS first, instead
#                 of using the manifests `docker buildx bake preflight` exported there.
#   --plan-only   resolve the sources (fails on anything unresolved) without building them.
#   --only        build only the named roots (plan.tsv's root column), e.g. --only git.
#   <bake args>   passed to the build, e.g. --progress=plain.
#
# Output: out/sources/plan.tsv, and one OCI layout per source image in out/sources/oci/<tag>/.
# docker-bake.hcl's variables apply: MANIFESTS, SOURCE_REUSE, and SOURCE_PUSH with
# SOURCE_REPOSITORY to push to a registry instead.
set -euo pipefail

cd "$(dirname "$0")/.."

from_image=
plan_only=false
only=()
while (($#)); do
	case $1 in
	--from-image) from_image=${2:?--from-image needs an image} && shift ;;
	--plan-only) plan_only=true ;;
	--only) only+=("${2:?--only needs a root}") && shift ;;
	--) shift && break ;;
	*)
		echo "build-sources: unknown argument $1" >&2
		exit 2
		;;
	esac
	shift
done

manifests=${MANIFESTS:-out/preflight}
if [[ -n $from_image ]]; then
	rm -rf "$manifests"
	mkdir -p "$manifests"
	docker run --rm --entrypoint cat "$from_image" /legal/manifest.tsv >"$manifests/manifest.tsv"
fi
if [[ -z $(find "$manifests" -name manifest.tsv 2>/dev/null) ]]; then
	echo "build-sources: no manifest.tsv in $manifests; run \`docker buildx bake preflight\` or pass --from-image" >&2
	exit 1
fi

export MANIFESTS=$manifests
SOURCE_RECIPE_REVISION=$(git log -1 --format=%H -- scripts/build-source-image.sh 2>/dev/null || true)
if [[ -n $(git status --porcelain -- scripts/build-source-image.sh 2>/dev/null) ]]; then
	SOURCE_RECIPE_REVISION=uncommitted
fi
SOURCE_RECIPE_REPOSITORY=$(git remote get-url origin 2>/dev/null || true)
export SOURCE_RECIPE_REVISION SOURCE_RECIPE_REPOSITORY

rm -rf out/sources/plans out/sources/sources.hcl out/sources/plan.tsv
docker buildx bake source-plan
cut -f1,2,5,6 out/sources/plan.tsv | column -t -s $'\t'
$plan_only && exit 0

targets=()
if ((${#only[@]})); then
	for root in "${only[@]}"; do
		found=$(awk -F'\t' -v r="$root" '$1 == "build" && $5 == r { print "source-" substr($3, 8, 16) }' out/sources/plan.tsv)
		if [[ -z $found ]]; then
			echo "build-sources: no source image to build for $root in out/sources/plan.tsv" >&2
			exit 1
		fi
		for target in $found; do
			targets+=("$target")
		done
	done
else
	targets=(sources)
fi
docker buildx bake -f docker-bake.hcl -f out/sources/sources.hcl "$@" "${targets[@]}"
