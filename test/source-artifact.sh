#!/usr/bin/env bash
# Run the source collector in a disposable container with an artifact fixture.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/legal/attribution/git/build/scripts/build" "$work/config"
recipe=$work/legal/attribution/git/build
printf 'artifact recipe\n' >"$recipe/Dockerfile.git"
printf 'artifact script\n' >"$recipe/scripts/build/git.sh"
producer=1111111111111111111111111111111111111111
consumer=2222222222222222222222222222222222222222
printf 'revision: %s\nrepository: https://example.com/producer\n' "$producer" >"$recipe/ORIGIN"
printf '{"elections":[]}\n' >"$work/config/license-elections.json"
printf '{"repositories":[]}\n' >"$work/config/source-apt.json"
sha=$(shasum -a 256 "$recipe/scripts/build/git.sh" | cut -d' ' -f1)
printf 'component\tversion\tarch\tlicense\tnotices\tsource\n' >"$work/legal/manifest.tsv"
printf 'git\t2.56.0\tarm64\tGPL-2.0\t-\tsource:https://example.com/git.tar.xz sha256:%s build-script:scripts/build/git.sh sha256:%s\n' "$sha" "$sha" >>"$work/legal/manifest.tsv"
collect() {
	docker run --rm --network none --user root --entrypoint bash \
		-e "REVISION=$consumer" -e REPOSITORY_URL=https://example.com/consumer \
		--mount "type=bind,source=$PWD/scripts/collect-source.sh,target=/collector.sh,readonly" \
		--mount "type=bind,source=$work/legal,target=/legal" \
		--mount "type=bind,source=$work/config,target=/config,readonly" \
		"${TEST_IMAGE:-devcontainer:local}" /collector.sh /config
}
collect
grep -Fq "https://example.com/producer/blob/$producer/Dockerfile.git" "$work/legal/source.tsv"
grep -Fq "https://example.com/producer/blob/$producer/scripts/build/git.sh" "$work/legal/source.tsv"
if grep -Fq "$consumer" "$work/legal/source.tsv"; then
	echo 'Artifact source incorrectly points at the consumer revision' >&2
	exit 1
fi
printf 'revision: invalid\nrepository: https://example.com/producer\n' >"$recipe/ORIGIN"
if collect; then
	echo 'Invalid artifact origin should fail collection' >&2
	exit 1
fi
rm "$recipe/ORIGIN"
collect
grep -Fq "https://example.com/consumer/blob/$consumer/scripts/build/git.sh" "$work/legal/source.tsv"
echo 'Artifact source provenance passed'
