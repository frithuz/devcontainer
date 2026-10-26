#!/usr/bin/env bash
# Derive the source images an image needs from its /legal/manifest.tsv files (one per platform),
# and resolve each one's exact inputs without fetching the source (docs/legal.md#source-images):
# - apt: every copyleft or non-machine-readable package's source package and version, found in
#   its repository's Sources index (scripts/source-apt.yaml), with the .dsc and archive digests;
# - git: the commit of each root program's tag (scripts/source-roots.yaml), checked against the
#   revision recorded in the binary, and the Go modules the binaries were built from;
# - bundle: the commit of the bundle's tag and the digests of its copyleft archives.
# Every copyleft component that isn't an apt package or a Go module must be covered by a root,
# a documented gap, or a license election. Unresolved roots fail; gaps are reported.
#
# Usage: plan-sources.sh --config <dir> [--check] [--out <dir>] [--reuse <repository>] <manifest.tsv>...
#   --config the Dockerfile's config stage output: source-apt.json and source-roots.json, from
#            scripts/*.yaml validated against their schemas (`docker buildx bake config` exports
#            it to out/config).
#   --check  resolve and report only; write nothing.
#   --out    write plan.tsv (summary), plans/<tag>/plan.json (one per source image, read by
#            scripts/build-source-image.sh), and sources.hcl (a bake target per source image to
#            build, and the "sources" group). Default: out/sources.
#   --reuse  registry repository holding published source-* tags. Tags already there with the
#            same key are reused (left out of the "sources" group); a different key is an error.
# Environment:
#   SOURCE_RECIPE_REPOSITORY, SOURCE_RECIPE_REVISION: this repository's URL and the last commit
#     that changed scripts/build-source-image.sh; part of every source image's identity.
#   SOURCE_PLANS_CONTEXT: the --out directory as docker buildx bake sees it (default: out/sources).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
readonly here
readonly recipe_script=$here/build-source-image.sh
# Licenses that owe source. NOASSERTION (an apt copyright file that isn't machine-readable)
# can't be ruled out, so it owes source too.
readonly copyleft='GPL|MPL|EPL|CDDL|EUPL|NOASSERTION'
# The annotations below are part of every source image but not otherwise of its key. Bump this
# when they change, so every source image is rebuilt with the new ones.
readonly annotations_version=1

config=
check=false
out=out/sources
reuse=
manifests=()
while (($#)); do
	case $1 in
	--config) config=${2:?--config needs a directory} && shift ;;
	--check) check=true ;;
	--out) out=${2:?--out needs a directory} && shift ;;
	--reuse) reuse=${2:?--reuse needs a repository} && shift ;;
	-*)
		echo "plan-sources: unknown option $1" >&2
		exit 2
		;;
	*) manifests+=("$1") ;;
	esac
	shift
done
if [[ -z $config ]] || ((${#manifests[@]} == 0)); then
	echo "usage: plan-sources.sh --config <dir> [--check] [--out <dir>] [--reuse <repository>] <manifest.tsv>..." >&2
	exit 2
fi
readonly apt_json=$config/source-apt.json roots_json=$config/source-roots.json
readonly plans_context=${SOURCE_PLANS_CONTEXT:-out/sources}

errors=0
gaps=0
error() {
	echo "plan-sources: ERROR: $*" >&2
	errors=$((errors + 1))
}
note() {
	echo "plan-sources: $*" >&2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

recipe=$(jq -cn \
	--arg repository "${SOURCE_RECIPE_REPOSITORY:-local}" \
	--arg revision "${SOURCE_RECIPE_REVISION:-uncommitted}" \
	--arg digest "sha256:$(sha256sum "$recipe_script" | cut -d' ' -f1)" --argjson annotations "$annotations_version" \
	'{repository: $repository, revision: $revision, path: "scripts/build-source-image.sh", digest: $digest, annotations: $annotations}')
readonly recipe
if [[ -z ${SOURCE_RECIPE_REVISION:-} ]]; then
	note "SOURCE_RECIPE_REVISION is unset; keys won't match published source images"
fi

# All manifests as one table: architecture, component, version, license, source.
rows=$work/rows.tsv
for manifest in "${manifests[@]}"; do
	arch=$(awk -F'\t' 'NR > 1 && $3 != "all" { print $3; exit }' "$manifest")
	[[ -n $arch ]] || error "$manifest: no architecture-specific rows"
	awk -F'\t' -v OFS='\t' -v arch="$arch" 'NR > 1 { print arch, $1, $2, $4, $6 }' "$manifest"
done >"$rows"
mapfile -t arches < <(cut -f1 "$rows" | sort -u)

# Source images, keyed by key: their plan (tag, key, identity, annotations, fetch, expect) and
# the components they cover, as "<arch>:<component>" lines.
declare -A plan covers
# Gaps and elections: "<kind>\t<root>\t<note>" -> covered components.
declare -A decisions

# add <plan json> <covered component>...
add() {
	local json=$1 key
	shift
	key=$(jq -r .key <<<"$json")
	plan[$key]=$json
	covers[$key]+=$(printf '%s\n' "$@")$'\n'
}

sanitize() {
	echo "${1//[^A-Za-z0-9_.-]/_}"
}

# finish <identity json> <fetch json> <expect json> <source url>: key, tag, and annotations.
finish() {
	local identity=$1 fetch=$2 expect=$3 url=$4 key root version readable
	key=sha256:$(jq -cjS . <<<"$identity" | sha256sum | cut -d' ' -f1)
	root=$(jq -r .root <<<"$identity")
	version=$(jq -r .version <<<"$identity")
	readable="source-$(sanitize "$root")-$(sanitize "$version")"
	jq -cn --argjson identity "$identity" --argjson fetch "$fetch" --argjson expect "$expect" \
		--arg key "$key" --arg tag "${readable:0:119}-${key:7:8}" --arg url "$url" '{
			tag: $tag, key: $key, identity: $identity, fetch: $fetch, expect: $expect,
			annotations: ({
				"org.opencontainers.image.title": "\($identity.root) \($identity.version)",
				"org.opencontainers.image.description": ("Corresponding source for " + (
					if $identity.kind == "apt" then
						($identity.ref.repository | sub("^https?://"; "")) as $repository
						| if $repository == "archive.ubuntu.com/ubuntu" then
							"Ubuntu source package \($identity.root) \($identity.version): its .dsc and archives from \($identity.ref.suite)"
						else
							"apt source package \($identity.root) \($identity.version): its .dsc and archives from \($repository) \($identity.ref.suite)"
						end
					elif $identity.kind == "git" then
						"\($identity.root) \($identity.version): upstream git at commit \($identity.ref.commit[0:12]) with its Go modules vendored"
					else
						"\($identity.root) \($identity.version): its vendored build scripts and the copyleft archives it bundles"
					end) + ", as shipped in frithuz/devcontainer."),
				"org.opencontainers.image.source": $url,
				"org.opencontainers.image.version": $identity.version,
				"vnd.frithuz.devcontainer.source.key": $key
			} + if $identity.ref.commit then {"org.opencontainers.image.revision": $identity.ref.commit} else {} end)
		}'
}

# Peeled commit of a tag: <repository> <tag>.
tag_commit() {
	local lines
	lines=$(git ls-remote "$1" "refs/tags/$2" "refs/tags/$2^{}") || return 1
	awk -v t="refs/tags/$2" '$2 == t "^{}" { peeled = $1 } $2 == t { direct = $1 } END { print peeled ? peeled : direct }' <<<"$lines"
}

# --- apt -------------------------------------------------------------------------------------
declare -A apt_url apt_suites apt_components apt_keyring apt_prefixes
apt_names=()
# One line per repository: lists space-separated, "-" for a repository without source packages.
while IFS=$'\t' read -r name prefixes url suites components keyring; do
	apt_names+=("$name")
	apt_prefixes[$name]=$prefixes apt_url[$name]=$url apt_suites[$name]=$suites
	apt_components[$name]=$components apt_keyring[$name]=$keyring
done < <(jq -r '.repositories[] | [.name, (.binaryUrlPrefixes | join(" ")),
	(.source // {} | .url // "-", (.suites // ["-"] | join(" ")), (.components // ["-"] | join(" ")), .signedBy // "-")] | @tsv' "$apt_json")

apt_repo_of() {
	local name prefix
	for name in "${apt_names[@]}"; do
		for prefix in ${apt_prefixes[$name]}; do
			[[ $1 == "$prefix"* ]] && echo "$name" && return
		done
	done
}

# Sources indexes of a repository: package, version, suite, directory, files
# (name:sha256:size, comma-separated), in suite order.
sources_index() {
	local name=$1 index=$work/sources-$1.tsv suite component
	if [[ ! -e $index ]]; then
		for suite in ${apt_suites[$name]}; do
			for component in ${apt_components[$name]}; do
				curl -fsSL --retry 3 "${apt_url[$name]}/dists/$suite/$component/source/Sources.gz" | gunzip |
					awk -v OFS='\t' -v suite="$suite" '
						function flush() { if (pkg != "") print pkg, ver, suite, dir, files; pkg = ver = dir = files = "" }
						/^$/ { flush(); in_sha = 0; next }
						/^ / { if (in_sha) files = files (files == "" ? "" : ",") $3 ":" $1 ":" $2; next }
						{ in_sha = 0 }
						/^Package:/ { pkg = $2 }
						/^Version:/ { ver = $2 }
						/^Directory:/ { dir = $2 }
						/^Checksums-Sha256:/ { in_sha = 1 }
						END { flush() }'
			done
		done >"$index" || {
			error "$name: can't read the Sources indexes of ${apt_url[$name]}"
			: >"$index"
		}
	fi
	echo "$index"
}

# Copyleft apt packages: repository, source package, version, architecture, component.
apt_needed=$work/apt.tsv
while IFS=$'\t' read -r arch comp _ license source; do
	read -r src uri _ <<<"$source"
	src=${src#src:}
	repo=$(apt_repo_of "$uri")
	if [[ -z $repo ]]; then
		error "$comp ($arch): $uri is in no repository listed in scripts/source-apt.yaml"
		continue
	fi
	printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "${src%%=*}" "${src#*=}" "$arch" "$comp"
done < <(awk -F'\t' -v OFS='\t' -v re="$copyleft" '$2 ~ /^deb:/ && $4 ~ re' "$rows") | sort -u >"$apt_needed"

while IFS=$'\t' read -r repo pkg version; do
	mapfile -t covered < <(awk -F'\t' -v r="$repo" -v p="$pkg" -v v="$version" '$1 == r && $2 == p && $3 == v { print $4 ":" $5 }' "$apt_needed")
	if [[ ${apt_url[$repo]} == - ]]; then
		error "$pkg $version (${covered[*]}): repository $repo publishes no source packages; add a git root to scripts/source-roots.yaml"
		continue
	fi
	index=$(sources_index "$repo")
	entry=$(awk -F'\t' -v OFS='\t' -v p="$pkg" -v v="$version" '$1 == p && $2 == v { print $3, $4, $5; exit }' "$index")
	if [[ -z $entry ]]; then
		error "$pkg $version (${covered[*]}): not in the Sources indexes of ${apt_url[$repo]} (${apt_suites[$repo]})"
		continue
	fi
	IFS=$'\t' read -r suite dir files <<<"$entry"
	fetch=$(jq -cn --arg repository "${apt_url[$repo]}" --arg suite "$suite" --arg components "${apt_components[$repo]}" \
		--arg keyring "${apt_keyring[$repo]}" --arg package "$pkg" --arg version "$version" --arg directory "$dir" --arg files "$files" '{
			kind: "apt", repository: $repository, suite: $suite, components: ($components | split(" ")),
			signedBy: $keyring, package: $package, version: $version, directory: $directory,
			files: [$files | split(",")[] | split(":") | {name: .[0], digest: "sha256:\(.[1])", size: (.[2] | tonumber)}] | sort_by(.name)
		}')
	dsc=$(jq -r '.files[] | select(.name | endswith(".dsc")) | .digest' <<<"$fetch")
	if [[ -z $dsc ]]; then
		error "$pkg $version: no .dsc in its Sources entry"
		continue
	fi
	identity=$(jq -cn --arg repository "${apt_url[$repo]}" --arg suite "$suite" --arg package "$pkg" --arg version "$version" \
		--arg dsc "$dsc" --argjson recipe "$recipe" '{
			kind: "apt", root: $package, version: $version,
			ref: {repository: $repository, suite: $suite, package: $package, version: $version, dscDigest: $dsc},
			recipe: $recipe
		}')
	add "$(finish "$identity" "$fetch" '{}' "${apt_url[$repo]}")" "${covered[@]}"
done < <(cut -f1-3 "$apt_needed" | sort -u)

# --- Roots from source-roots.yaml --------------------------------------------------------------
# Tokens covered by any root, gap, or election (globs), for the coverage check below.
cover_patterns=()

# One line per root, gap, and election: name, kind, repository, tag, covers (space-separated; for
# git, the main module then the binaries), recipe (git: vendoring; bundle: comma-separated
# subpaths), note (gap: reason; election: license). Absent fields are "-".
while IFS=$'\t' read -r root kind repo ref cover_list recipe_opt root_note; do
	read -ra tokens <<<"$cover_list"
	cover_patterns+=("${tokens[@]}")
	case $kind in
	git)
		main=${tokens[0]#go-module:}
		bins=("${tokens[@]:1}")
		# Main module version and recorded revision, per architecture.
		mapfile -t found < <(awk -F'\t' -v OFS='\t' -v c="go-module:$main" '$2 == c && $5 ~ / main-module / {
				rev = "-"; if (match($5, /revision:[0-9a-f]+/)) rev = substr($5, RSTART + 9, RLENGTH - 9)
				print $1, $3, rev }' "$rows")
		if ((${#found[@]} == 0)); then
			error "$root: $main isn't in any manifest; remove or update its entry in scripts/source-roots.yaml"
			continue
		fi
		mapfile -t versions < <(printf '%s\n' "${found[@]}" | cut -f2 | sort -u)
		for version in "${versions[@]}"; do
			tag=${ref//\{version\}/$version}
			if ! commit=$(tag_commit "$repo" "$tag") || [[ -z $commit ]]; then
				error "$root $version: no tag $tag in $repo"
				continue
			fi
			mapfile -t revisions < <(printf '%s\n' "${found[@]}" | awk -F'\t' -v v="$version" '$2 == v && $3 != "-" { print $3 }' | sort -u)
			for rev in "${revisions[@]}"; do
				[[ $commit == "$rev"* ]] || error "$root $version: tag $tag is commit $commit, but the binaries were built from $rev"
			done
			((${#revisions[@]})) || note "$root $version: the binaries record no revision; trusting tag $tag ($commit)"
			mapfile -t ver_arches < <(printf '%s\n' "${found[@]}" | awk -F'\t' -v v="$version" '$2 == v { print $1 }' | sort -u)
			# Every module compiled into the covered binaries, on the architectures at this version.
			expect=$(awk -F'\t' -v OFS='\t' -v arches="${ver_arches[*]}" -v bins="${bins[*]}" -v main="go-module:$main" '
					BEGIN { split(arches, a, " "); for (i in a) want[a[i]] = 1; split(bins, b, " "); for (i in b) bin[b[i]] = 1 }
					want[$1] && $2 ~ /^go-module:/ && $2 != main && match($5, /embedded-in:[^ ]+/) {
						n = split(substr($5, RSTART + 12, RLENGTH - 12), e, ",")
						for (i = 1; i <= n; i++) if (bin[e[i]]) { print substr($2, 11), $3; break }
					}' "$rows" | sort -u | jq -cnR '{modules: [inputs | split("\t") | {path: .[0], version: .[1]}]}')
			fetch=$(jq -cn --arg repository "$repo" --arg commit "$commit" --arg vendoring "$recipe_opt" --arg main "$main" \
				'{kind: "git", repository: $repository, commit: $commit, subpaths: [], vendoring: $vendoring, mainModule: $main}')
			identity=$(jq -cn --arg root "$root" --arg version "$version" --arg repository "$repo" --arg commit "$commit" \
				--arg tag "$tag" --argjson recipe "$recipe" \
				'{kind: "git", root: $root, version: $version, ref: {repository: $repository, commit: $commit, tag: $tag}, recipe: $recipe}')
			mapfile -t covered < <(for a in "${ver_arches[@]}"; do printf '%s\n' "$a:go-module:$main" "${bins[@]/#/$a:}"; done)
			add "$(finish "$identity" "$fetch" "$expect" "$repo")" "${covered[@]}"
		done
		;;
	bundle)
		subpaths=$recipe_opt
		for arch in "${arches[@]}"; do
			version=$(awk -F'\t' -v a="$arch" -v c="${tokens[0]}" '$1 == a && $2 == c { print $3; exit }' "$rows")
			[[ -n $version ]] || continue
			tag=${ref//\{version\}/$version}
			if ! commit=$(tag_commit "$repo" "$tag") || [[ -z $commit ]]; then
				error "$root $version: no tag $tag in $repo"
				continue
			fi
			covered=()
			archives=()
			while IFS=$'\t' read -r comp license source; do
				for pattern in "${tokens[@]}"; do
					# shellcheck disable=SC2053 # covers entries are globs.
					[[ $comp == $pattern ]] || continue
					covered+=("$arch:$comp")
					if [[ $license =~ $copyleft && $source =~ source:([^ ]+)\ sha256:([0-9a-f]{64}) ]]; then
						archives+=("${BASH_REMATCH[1]} sha256:${BASH_REMATCH[2]}")
					fi
					break
				done
			done < <(awk -F'\t' -v OFS='\t' -v a="$arch" '$1 == a { print $2, $4, $5 }' "$rows")
			parts=$(printf '%s\n' "${archives[@]}" | jq -cnR --arg repository "$repo" --arg commit "$commit" --arg subpaths "$subpaths" '
				[inputs | select(. != "") | split(" ") | {type: "archive", url: .[0], digest: .[1]}]
				+ [{type: "git", repository: $repository, commit: $commit, subpaths: ($subpaths | split(",") | sort)}]
				| sort_by(.type, .url // .repository)')
			identity=$(jq -cn --arg root "$root" --arg version "$version" --argjson parts "$parts" --argjson recipe "$recipe" \
				'{kind: "bundle", root: $root, version: $version, ref: {parts: $parts}, recipe: $recipe}')
			fetch=$(jq -cn --argjson parts "$parts" '{kind: "bundle", parts: $parts}')
			add "$(finish "$identity" "$fetch" '{}' "$repo")" "${covered[@]}"
		done
		;;
	gap | election)
		mapfile -t covered < <(awk -F'\t' '{ print $1 "\t" $2 }' "$rows" | while IFS=$'\t' read -r arch comp; do
			for pattern in "${tokens[@]}"; do
				# shellcheck disable=SC2053 # covers entries are globs.
				[[ $comp == $pattern ]] && echo "$arch:$comp" && break
			done
		done)
		((${#covered[@]})) && decisions["$kind"$'\t'"$root"$'\t'"$root_note"]=$(printf '%s\n' "${covered[@]}")
		;;
	*) error "$root: unknown kind $kind in scripts/source-roots.yaml" ;;
	esac
done < <(jq -r '
	(.roots[] | [.name, .kind, .repository, .tag,
		(if .kind == "git" then ["go-module:" + .module] + .binaries else .components end | join(" ")),
		.vendoring // (.subpaths | join(",")), .note // "-"]),
	(.gaps[] | [.name, "gap", .repository // "-", "-", (.components | join(" ")), "-", .reason]),
	(.elections[] | [.name, "election", "-", "-", (.components | join(" ")), "-", .license])
	| @tsv' "$roots_json")

# --- Coverage --------------------------------------------------------------------------------
# Go modules' licenses aren't in manifest.tsv (NOASSERTION); the Go programs that owe source
# are listed in source-roots.yaml by hand.
while IFS=$'\t' read -r arch comp license; do
	for pattern in "${cover_patterns[@]}"; do
		# shellcheck disable=SC2053 # covers entries are globs.
		[[ $comp == $pattern ]] && continue 2
	done
	error "$comp ($arch, $license) owes source but no root in scripts/source-roots.yaml covers it"
done < <(awk -F'\t' -v OFS='\t' -v re="$copyleft" '$2 !~ /^(deb|go-module):/ && $4 ~ re { print $1, $2, $4 }' "$rows")

for decision in "${!decisions[@]}"; do
	IFS=$'\t' read -r kind root root_note <<<"$decision"
	if [[ $kind == gap ]]; then
		gaps=$((gaps + 1))
		note "gap: $root ($(sort -u <<<"${decisions[$decision]}" | paste -sd' ' -)): $root_note"
	fi
done

# --- Reuse -----------------------------------------------------------------------------------
declare -A status
for key in "${!plan[@]}"; do
	status[$key]=build
done
if [[ -n $reuse ]]; then
	if published=$(oras repo tags "$reuse" 2>"$work/oras.err"); then
		:
	elif grep -qiE 'name unknown|not found' "$work/oras.err"; then
		note "$reuse doesn't exist yet; nothing to reuse"
		published=
	else
		error "can't list the tags of $reuse: $(cat "$work/oras.err")"
		published=
	fi
	for key in "${!plan[@]}"; do
		tag=$(jq -r .tag <<<"${plan[$key]}")
		grep -qxF "$tag" <<<"$published" || continue
		if ! existing=$(oras manifest fetch "$reuse:$tag" | jq -r '.annotations["vnd.frithuz.devcontainer.source.key"] // empty'); then
			error "can't read $reuse:$tag"
		elif [[ $existing == "$key" ]]; then
			status[$key]=reused
		else
			error "$reuse:$tag exists with key ${existing:-none}, expected $key; not overwriting it"
		fi
	done
fi

# --- Report and write ------------------------------------------------------------------------
build=0 reused=0
for key in "${!plan[@]}"; do
	[[ ${status[$key]} == build ]] && build=$((build + 1)) || reused=$((reused + 1))
done
note "${#plan[@]} source images ($build to build, $reused reused), $gaps gaps, $errors errors"

if ! $check; then
	rm -rf "$out/plans"
	mkdir -p "$out/plans"
	{
		printf 'status\ttag\tkey\tkind\troot\tversion\tcovers\tnote\n'
		for key in "${!plan[@]}"; do
			jq -r --arg status "${status[$key]}" --arg covers "$(sort -u <<<"${covers[$key]}" | grep . | paste -sd' ' -)" \
				'[$status, .tag, .key, .identity.kind, .identity.root, .identity.version, $covers, "-"] | @tsv' <<<"${plan[$key]}"
		done | sort -t$'\t' -k2,2
		for decision in "${!decisions[@]}"; do
			IFS=$'\t' read -r kind root root_note <<<"$decision"
			printf '%s\t-\t-\t%s\t%s\t-\t%s\t%s\n' "$kind" "$kind" "$root" "$(sort -u <<<"${decisions[$decision]}" | paste -sd' ' -)" "$root_note"
		done | sort
	} >"$out/plan.tsv"

	targets=()
	for key in "${!plan[@]}"; do
		tag=$(jq -r .tag <<<"${plan[$key]}")
		mkdir -p "$out/plans/$tag"
		jq -S . <<<"${plan[$key]}" >"$out/plans/$tag/plan.json"
		[[ ${status[$key]} == build ]] && targets+=("source-${key:7:16}")
	done
	# HCL strings: JSON escaping, plus HCL's template sequences.
	# shellcheck disable=SC2016 # jq program, not shell.
	hcl='def hcl: tojson | gsub("\\$\\{"; "$${") | gsub("%\\{"; "%%{");'
	{
		echo '# Generated by scripts/plan-sources.sh: one target per source image to build.'
		echo '# docker buildx bake -f docker-bake.hcl -f out/sources/sources.hcl sources'
		printf 'group "sources" {\n  targets = %s\n}\n' "$(printf '%s\n' "${targets[@]}" | grep . | sort | jq -cnR '[inputs]')"
		for key in "${!plan[@]}"; do
			[[ ${status[$key]} == build ]] || continue
			jq -r --arg name "source-${key:7:16}" --arg context "$plans_context" "$hcl"'
				"\ntarget \"\($name)\" {",
				"  inherits = [\"source\"]",
				"  contexts = { root-plan = \("\($context)/plans/\(.tag)" | hcl) }",
				"  args = { KIND = \(.identity.kind | hcl) }",
				"  tags = [\"${SOURCE_REPOSITORY}:\(.tag)\"]",
				"  annotations = [",
				(.annotations | to_entries | sort_by(.key)[] | "    \("index,manifest:\(.key)=\(.value)" | hcl),"),
				"  ]",
				"  output = source_output(\(.tag | hcl))",
				"}"' <<<"${plan[$key]}"
		done
	} >"$out/sources.hcl"
	note "wrote $out/plan.tsv, $out/sources.hcl, and $out/plans/"
fi

if ((errors > 0)); then
	exit 1
fi
