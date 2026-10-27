#!/usr/bin/env bash
# Attach or check an image's source indexes (docs/legal.md#publishing): exactly one referrer of
# artifact type application/vnd.frithuz.devcontainer.source.v1 per subject, the image index and
# each platform manifest. A source index lists, by digest, a record mapping the subject's
# components to their source images, gaps, and elections, then the source images themselves
# (docs/data-model.md#source-index). Runs on the host, including macOS's bash 3.2, with oras and jq.
#
#   scripts/source-indexes.sh attach [--referrers api|tag] <plan.tsv> <repository> <digest>
#   scripts/source-indexes.sh inherit [--referrers api|tag] <base> <base digest> <repository> <digest>
#   scripts/source-indexes.sh check [--referrers api|tag] <repository> <digest>
#
#   attach       build each subject's source index from plan.tsv (scripts/plan-sources.sh) and push
#                it by digest, untagged. Every planned source image must already be in <repository>.
#                A subject that already has the same source index keeps it. Any other source index
#                fails, because GHCR can't replace a referrer. Then checks.
#   inherit      for an image built FROM <base>@<base digest> that adds no copyleft component, such
#                as a sandbox kit: give each subject the source index of the base's matching subject,
#                the index or the same platform, after checking that the base's layers start the
#                subject's. Copies what the base's source index lists from <base> into <repository>
#                first, with the source images' tags. Keeps or fails on an existing source index as
#                attach does. Then checks.
#   check        require exactly one source index per subject, and everything it lists in
#                <repository>.
#   --referrers  how oras finds and records referrers: api (the Referrers API, Quay) or tag
#                (fallback tags, GHCR), in every repository the mode reads or writes. Default: oras
#                detects it.
#
# Output: one line per subject, image index first: subject (index or linux/<arch>), its digest,
# its source index's digest, and the number of source images listed, tab-separated.
set -euo pipefail

readonly artifact_type=application/vnd.frithuz.devcontainer.source.v1
readonly record_type=application/vnd.frithuz.devcontainer.source.record.v1
readonly index_type=application/vnd.oci.image.index.v1+json
readonly manifest_type=application/vnd.oci.image.manifest.v1+json

usage() {
	echo "usage: source-indexes.sh attach [--referrers api|tag] <plan.tsv> <repository> <digest>" >&2
	echo "       source-indexes.sh inherit [--referrers api|tag] <base> <base digest> <repository> <digest>" >&2
	echo "       source-indexes.sh check [--referrers api|tag] <repository> <digest>" >&2
	exit 2
}
fail() {
	echo "source-indexes: ERROR: $*" >&2
	exit 1
}
note() {
	echo "source-indexes: $*" >&2
}

mode=${1:-}
[[ $mode == attach || $mode == inherit || $mode == check ]] || usage
shift
spec=()
if [[ ${1:-} == --referrers ]]; then
	case ${2:-} in
	api) spec=(--distribution-spec v1.1-referrers-api) ;;
	tag) spec=(--distribution-spec v1.1-referrers-tag) ;;
	*) usage ;;
	esac
	shift 2
fi
plan='' base='' base_digest=''
if [[ $mode == attach ]]; then
	(($# > 0)) || usage
	plan=$1
	shift
elif [[ $mode == inherit ]]; then
	(($# > 2)) || usage
	base=$1 base_digest=$2
	shift 2
fi
(($# == 2)) || usage
repository=$1 digest=$2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# descriptor <file> <media type>
descriptor() {
	jq -cn --arg mediaType "$2" --arg digest "sha256:$(sha256 "$1")" --argjson size "$(wc -c <"$1" | tr -d ' ')" \
		'{mediaType: $mediaType, digest: $digest, size: $size}'
}

# referrers <digest> [<repository>]: digests of the source indexes whose subject is <digest>.
referrers() {
	oras discover ${spec[@]+"${spec[@]}"} --artifact-type "$artifact_type" --depth 1 --format json "${2:-$repository}@$1" |
		jq -r '.referrers[].digest'
}

# subjects <repository> <digest>: one line per subject, name (index or linux/<arch>), architecture
# ("-" for the index), descriptor.
subjects() {
	local index
	index=$(oras manifest fetch "$1@$2")
	[[ $(jq -r .mediaType <<<"$index") == "$index_type" ]] || fail "$1@$2 isn't an OCI image index"
	printf 'index\t-\t%s\n' "$(oras manifest fetch --descriptor "$1@$2" | jq -c '{mediaType, digest, size}')"
	jq -r '.manifests[] | select(.platform.os == "linux")
		| ["linux/\(.platform.architecture)", .platform.architecture, ({mediaType, digest, size} | tojson)] | @tsv' <<<"$index"
}
subjects "$repository" "$digest" >"$work/subjects.tsv"
(($(wc -l <"$work/subjects.tsv") > 1)) || fail "$repository@$digest has no linux platform manifests"

# select_arch <arch> <file>: rows whose first column (space-separated <arch>:<component> covers)
# has a component of <arch>, with only those kept. "-" keeps every row whole.
select_arch() {
	awk -F'\t' -v OFS='\t' -v arch="$1" '{
		n = split($1, c, " "); kept = ""
		for (i = 1; i <= n; i++) if (arch == "-" || index(c[i], arch ":") == 1) kept = kept (kept == "" ? "" : " ") c[i]
		if (kept != "") { $1 = kept; print }
	}' "$2"
}

attach() {
	# Source images: covers, descriptor in <repository>, record entry. Sorted by tag.
	# Decisions: covers, kind (gap or election), record entry.
	: >"$work/sources.tsv"
	: >"$work/decisions.tsv"
	local status tag key kind root version covers decision_note desc
	while IFS=$'\t' read -r status tag key kind root version covers decision_note; do
		case $status in
		build | reused)
			desc=$(oras manifest fetch --descriptor "$repository:$tag") || fail "source image $repository:$tag is missing"
			jq -rn --argjson desc "$desc" --arg tag "$tag" --arg key "$key" --arg kind "$kind" --arg root "$root" \
				--arg version "$version" --arg covers "$covers" '[
					$covers,
					($desc | {mediaType, digest, size, annotations: {
						"org.opencontainers.image.title": "\($root) \($version)",
						"vnd.frithuz.devcontainer.source.key": $key
					}} | tojson),
					({tag: $tag, key: $key, kind: $kind, root: $root, version: $version, digest: $desc.digest} | tojson)
				] | @tsv' >>"$work/sources.tsv"
			;;
		gap)
			jq -rn --arg root "$root" --arg covers "$covers" --arg reason "$decision_note" \
				'[$covers, "gap", ({root: $root, reason: $reason} | tojson)] | @tsv' >>"$work/decisions.tsv"
			;;
		election)
			jq -rn --arg root "$root" --arg covers "$covers" --arg license "$decision_note" \
				'[$covers, "election", ({root: $root, license: $license} | tojson)] | @tsv' >>"$work/decisions.tsv"
			;;
		*) fail "$plan: unknown status $status" ;;
		esac
	done < <(tail -n +2 "$plan")
	[[ -s $work/sources.tsv ]] || fail "$plan lists no source images"

	printf '{}' >"$work/empty.json"
	local config name arch subject subject_digest layer record
	attached=false
	config=$(descriptor "$work/empty.json" application/vnd.oci.empty.v1+json)
	while IFS=$'\t' read -r name arch subject; do
		subject_digest=$(jq -r .digest <<<"$subject")
		select_arch "$arch" "$work/sources.tsv" >"$work/subject-sources.tsv"
		select_arch "$arch" "$work/decisions.tsv" >"$work/subject-decisions.tsv"
		[[ -s $work/subject-sources.tsv ]] || fail "$plan has no source images for $name"

		# The record, and a manifest that carries it as its only layer.
		jq -cjSn --arg platform "$name" --rawfile sources "$work/subject-sources.tsv" \
			--rawfile decisions "$work/subject-decisions.tsv" '
			def rows($text): $text | split("\n") | map(select(. != "") | split("\t"));
			def entries($kind): [rows($decisions)[] | select(.[1] == $kind) | (.[2] | fromjson) + {components: (.[0] | split(" "))}];
			{
				platform: (if $platform == "index" then null else $platform end),
				sources: [rows($sources)[] | (.[2] | fromjson) + {components: (.[0] | split(" "))}],
				gaps: entries("gap"),
				elections: entries("election")
			}' >"$work/record.json"
		layer=$(descriptor "$work/record.json" "$record_type+json")
		jq -cjSn --arg artifactType "$record_type" --argjson config "$config" --argjson layer "$layer" \
			--arg mediaType "$manifest_type" \
			'{schemaVersion: 2, mediaType: $mediaType, artifactType: $artifactType, config: $config, layers: [$layer]}' \
			>"$work/record-manifest.json"
		record=$(descriptor "$work/record-manifest.json" "$manifest_type" |
			jq -c --arg artifactType "$record_type" \
				'. + {artifactType: $artifactType, annotations: {"org.opencontainers.image.title": "source record"}}')

		jq -cjSn --arg mediaType "$index_type" --arg artifactType "$artifact_type" --argjson subject "$subject" \
			--argjson record "$record" --rawfile sources "$work/subject-sources.tsv" '{
				schemaVersion: 2, mediaType: $mediaType, artifactType: $artifactType,
				manifests: [$record] + [$sources | split("\n")[] | select(. != "") | split("\t")[1] | fromjson],
				subject: $subject
			}' >"$work/source-index.json"
		attached "$name" "$subject_digest" "$work/source-index.json"
		[[ $attached == false ]] || continue
		oras blob push "$repository@$(jq -r .digest <<<"$config")" "$work/empty.json" >/dev/null
		oras blob push "$repository@$(jq -r .digest <<<"$layer")" "$work/record.json" >/dev/null
		oras manifest push "$repository@$(jq -r .digest <<<"$record")" "$work/record-manifest.json" >/dev/null
		push_source_index "$name" "$work/source-index.json"
	done <"$work/subjects.tsv"
}

# attached <name> <subject digest> <source index file>: sets attached to true when the subject
# already has this source index, or false when it has none. Any other source index fails.
attached() {
	local want have
	want=$(descriptor "$3" "$index_type" | jq -r .digest)
	have=$(referrers "$2")
	attached=false
	if [[ $have == "$want" ]]; then
		note "$1: source index $want is already attached"
		attached=true
	elif [[ -n $have ]]; then
		fail "$1 ($2) already has source index $(paste -sd' ' - <<<"$have"), not $want." \
			"A subject can't get a second one (docs/legal.md#publishing)"
	fi
}

# push_source_index <name> <source index file>
push_source_index() {
	local want
	want=$(descriptor "$2" "$index_type" | jq -r .digest)
	oras manifest push ${spec[@]+"${spec[@]}"} "$repository@$want" "$2" >/dev/null
	note "$1: attached source index $want"
}

# layers <repository> <digest>: a platform manifest's layer digests, one per line.
layers() {
	oras manifest fetch "$1@$2" | jq -r '.layers[].digest'
}

inherit() {
	subjects "$base" "$base_digest" >"$work/base-subjects.tsv"
	local name arch subject subject_digest base_subject base_subject_digest found source_index listed tag copied
	attached=false
	: >"$work/copied"
	# Every platform is checked before anything is attached. The index has no layers of its own,
	# so it inherits only once each of its platforms has shown it's built on the base's.
	while IFS=$'\t' read -r name arch subject; do
		base_subject=$(awk -F'\t' -v name="$name" '$1 == name { print $3 }' "$work/base-subjects.tsv")
		[[ -n $base_subject ]] || fail "$base@$base_digest has no $name subject"
		[[ $name != index ]] || continue
		subject_digest=$(jq -r .digest <<<"$subject")
		base_subject_digest=$(jq -r .digest <<<"$base_subject")
		layers "$base" "$base_subject_digest" >"$work/base-layers"
		layers "$repository" "$subject_digest" >"$work/layers"
		head -n "$(wc -l <"$work/base-layers")" "$work/layers" | cmp -s "$work/base-layers" - ||
			fail "$name ($subject_digest) isn't built on $base@$base_subject_digest: its layers don't start with the base's"
	done <"$work/subjects.tsv"

	while IFS=$'\t' read -r name arch subject; do
		subject_digest=$(jq -r .digest <<<"$subject")
		base_subject=$(awk -F'\t' -v name="$name" '$1 == name { print $3 }' "$work/base-subjects.tsv")
		base_subject_digest=$(jq -r .digest <<<"$base_subject")

		found=$(referrers "$base_subject_digest" "$base")
		(($(grep -c . <<<"$found" || true) == 1)) ||
			fail "$base: $name ($base_subject_digest) doesn't have exactly one source index"
		source_index=$(oras manifest fetch "$base@$found")
		jq -cjS --argjson subject "$subject" '.subject = $subject' <<<"$source_index" >"$work/source-index.json"
		attached "$name" "$subject_digest" "$work/source-index.json"

		# Copied even when the source index is already attached, so a rerun completes an
		# interrupted copy. oras skips what's already there. The source record has no tag, and each
		# source image keeps the tag the base's record gives it.
		source_tags "$source_index" >"$work/listed.tsv"
		while IFS=$'\t' read -r listed tag; do
			grep -qxF "$listed" "$work/copied" && continue
			if [[ $tag == - ]]; then
				oras cp "$base@$listed" "$repository@$listed" >/dev/null
			else
				oras cp "$base@$listed" "$repository:$tag" >/dev/null
			fi
			echo "$listed" >>"$work/copied"
		done <"$work/listed.tsv"
		[[ $attached == true ]] || push_source_index "$name" "$work/source-index.json"
	done <"$work/subjects.tsv"
	copied=$(grep -c . "$work/copied" || true)
	note "copied or found $copied source records and source images from $base"
}

# source_tags <source index json>: each listed manifest's digest and tag ("-" for the record, and
# for a source image the record doesn't name), tab-separated.
source_tags() {
	local record_digest record_layer
	record_digest=$(jq -r --arg t "$record_type" '.manifests[] | select(.artifactType == $t) | .digest' <<<"$1")
	record_layer=$(oras manifest fetch "$base@$record_digest" | jq -r '.layers[0].digest')
	oras blob fetch --output "$work/base-record.json" "$base@$record_layer"
	jq -r --slurpfile record "$work/base-record.json" '
		($record[0].sources | map({key: .digest, value: .tag}) | from_entries) as $tags
		| .manifests[] | [.digest, ($tags[.digest] // "-")] | @tsv' <<<"$1"
}

check() {
	local name arch subject subject_digest found source_index count
	: >"$work/listed"
	: >"$work/report.tsv"
	while IFS=$'\t' read -r name arch subject; do
		subject_digest=$(jq -r .digest <<<"$subject")
		found=$(referrers "$subject_digest")
		count=$(grep -c . <<<"$found" || true)
		((count == 1)) || fail "$name ($subject_digest) has $count source indexes in $repository, expected 1"
		source_index=$(oras manifest fetch "$repository@$found")
		[[ $(jq -r .subject.digest <<<"$source_index") == "$subject_digest" ]] ||
			fail "$name: source index $found has another subject"
		jq -r '.manifests[].digest' <<<"$source_index" >>"$work/listed"
		printf '%s\t%s\t%s\t%s\n' "$name" "$subject_digest" "$found" \
			"$(jq --arg t "$record_type" '[.manifests[] | select(.artifactType != $t)] | length' <<<"$source_index")" >>"$work/report.tsv"
	done <"$work/subjects.tsv"
	local listed
	while read -r listed; do
		oras manifest fetch --descriptor "$repository@$listed" >/dev/null ||
			fail "a source index lists $listed, which isn't in $repository"
	done < <(sort -u "$work/listed")
	cat "$work/report.tsv"
}

if [[ $mode == attach ]]; then
	attach
elif [[ $mode == inherit ]]; then
	inherit
fi
check
