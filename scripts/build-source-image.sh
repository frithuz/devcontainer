#!/usr/bin/env bash
# Fetch and verify one root program's complete source, as planned by scripts/plan-sources.sh,
# into <out>/source/<root>/, with its record at <out>/source/SOURCE.json
# (docs/data-model.md#source-image). Runs in source.Dockerfile's fetch stages: Ubuntu with apt
# for kind apt, the Go toolchain and git for git and bundle.
# - apt: apt-get source --download-only from the planned repository and suite. apt checks the
#   files against the signed Sources index; they're checked against the plan here too.
# - git: the exact commit, exported with git archive, then its Go dependencies vendored
#   (go mod vendor) unless the repository commits vendor/. Every module the binaries were built
#   from (manifest.tsv) must be in vendor/modules.txt at the same version.
# - bundle: the git subpaths at the exact commit, plus archives checked against their SHA-256, and
#   the build scripts that compiled them (from the plan directory, checked the same way) under build/.
#
# Usage: build-source-image.sh <plan.json> <out>
set -euo pipefail

readonly plan=${1:?usage: build-source-image.sh <plan.json> <out>}
readonly out=${2:?}

die() {
	echo "build-source-image: ERROR: $*" >&2
	exit 1
}

key=$(jq -r .key "$plan")
actual=sha256:$(jq -cjS .identity "$plan" | sha256sum | cut -d' ' -f1)
[[ $actual == "$key" ]] || die "the plan's key $key doesn't match its identity ($actual)"
root=$(jq -r .identity.root "$plan")
kind=$(jq -r .identity.kind "$plan")
readonly key root kind
[[ $root =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] || die "unexpected root name: $root"
readonly dest=$out/source/$root

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
inputs=$work/inputs.jsonl
: >"$inputs"
vendored=null

# input <name> <role> <url> <file>: record a fetched input with its digest and size.
input() {
	jq -cn --arg name "$1" --arg role "$2" --arg url "$3" \
		--arg digest "sha256:$(sha256sum "$4" | cut -d' ' -f1)" --argjson size "$(stat -c %s "$4")" \
		'{name: $name, role: $role, url: $url, digest: $digest, size: $size}' >>"$inputs"
}

# verify <file> <sha256:hex>
verify() {
	local got
	got=sha256:$(sha256sum "$1" | cut -d' ' -f1)
	[[ $got == "$2" ]] || die "$1: sha256 $got, expected $2"
}

# fetch_git <repository> <commit> <dir> [subpath...]: export the commit's tree (or subpaths).
fetch_git() {
	local repo=$1 commit=$2 dir=$3 git=$work/git
	shift 3
	rm -rf "$git"
	git init -q "$git"
	git -C "$git" fetch -q --depth 1 "$repo" "$commit"
	[[ $(git -C "$git" rev-parse FETCH_HEAD) == "$commit" ]] || die "$repo: fetched $(git -C "$git" rev-parse FETCH_HEAD), expected $commit"
	# The repository's own export-ignore and export-subst attributes would drop or rewrite files;
	# the source image holds the tree as committed.
	printf '* -export-ignore -export-subst\n' >"$git/.git/info/attributes"
	git -C "$git" archive --format=tar -o "$work/tree.tar" "$commit" -- "$@"
	mkdir -p "$dir"
	tar -xf "$work/tree.tar" -C "$dir"
	input "$(basename "$repo")-${commit:0:12}.tar" source "$repo/tree/$commit" "$work/tree.tar"
}

# vendor_go <tree> <main module> <vendoring> <expected modules json>
vendor_go() {
	local tree=$1 main=$2 mode=$3 expect=$4 gomod moddir modules
	gomod=$(find "$tree" -name go.mod -not -path '*/vendor/*' -exec grep -lx "module $main" {} + | head -1)
	[[ -n $gomod ]] || die "no go.mod for module $main"
	moddir=$(dirname "$gomod")
	case $mode in
	go-vendor)
		[[ ! -e $moddir/vendor ]] || die "$main already commits vendor/; set vendoring: vendored in scripts/source-roots.yaml"
		(cd "$moddir" && GOFLAGS=-mod=mod go mod vendor)
		;;
	vendored) [[ -f $moddir/vendor/modules.txt ]] || die "$main commits no vendor/modules.txt; set vendoring: go-vendor in scripts/source-roots.yaml" ;;
	*) die "unknown vendoring $mode" ;;
	esac
	# modules.txt module lines: "# <path> <version> [=> <replacement> [<version>]]".
	modules=$(awk '$1 == "#" && $2 != "" { print $2 "\t" $3 "\t" ($4 == "=>" ? $5 "\t" $6 : "\t") }' "$moddir/vendor/modules.txt")
	local missing
	missing=$(jq -r '.modules[] | "\(.path)\t\(.version)"' <<<"$expect" | awk -F'\t' '
		NR == FNR { have[$1 "@" $2] = 1; if ($3 != "") have[$3 "@" $4] = 1; next }
		!have[$1 "@" $2] { print $1 "@" $2 }' <(printf '%s\n' "$modules") -)
	[[ -z $missing ]] || die "modules compiled into the binaries but not vendored at that version:"$'\n'"$missing"
	vendored=$(awk -F'\t' -v OFS='\t' '
		NR == FNR { if ($2 !~ /\/go\.mod$/) sum[$1 "@" $2] = $3; next }
		{ p = $3 != "" && $4 != "" ? $3 : $1; v = $3 != "" && $4 != "" ? $4 : $2; print p, v, sum[p "@" v] }' \
		<(sed 's/ /\t/g' "$moddir/go.sum" 2>/dev/null || true) <(printf '%s\n' "$modules") |
		sort -u | jq -cnR --arg path "${moddir#"$tree"/}/vendor" '
			{ecosystem: "go", path: ($path | ltrimstr("./")), modules: [inputs | split("\t") | {path: .[0], version: .[1], sum: .[2]}] | sort_by(.path)}')
	echo "build-source-image: vendor/ has every one of the $(jq '.modules | length' <<<"$expect") modules compiled into the binaries" >&2
}

mkdir -p "$dest"
case $kind in
apt)
	read -r repo suite package version directory keyring < <(jq -r '.fetch | [.repository, .suite, .package, .version, .directory, .signedBy] | join(" ")' "$plan")
	components=$(jq -r '.fetch.components | join(" ")' "$plan")
	mkdir -p "$work/sources.list.d"
	cat >"$work/sources.list.d/source.sources" <<SOURCES
Types: deb-src
URIs: $repo
Suites: $suite
Components: $components
Signed-By: $keyring
SOURCES
	# Only the planned repository: none of the image's own lists. /var/lib/apt/lists is a cache
	# mount kept between builds; apt-get update drops lists its sources don't name, so each
	# repository and suite keeps its lists in a directory of its own.
	lists=/var/lib/apt/lists/deb-src-$(sha256sum "$work/sources.list.d/source.sources" | cut -c1-16)
	apt_opts=(-o "Dir::Etc::SourceList=/dev/null" -o "Dir::Etc::SourceParts=$work/sources.list.d" -o "Dir::State::Lists=$lists")
	mkdir -p "$lists/partial"
	apt-get "${apt_opts[@]}" update
	# --only-source: the name is a source package, even where a binary package of the same name
	# is built from a different source (Ubuntu's coreutils binary comes from coreutils-from).
	(cd "$dest" && apt-get "${apt_opts[@]}" source --download-only --only-source "$package=$version")
	# Exactly the planned files, with the planned digests.
	expected=$(jq -r '.fetch.files[].name' "$plan" | sort)
	got=$(find "$dest" -mindepth 1 -printf '%P\n' | sort)
	[[ $got == "$expected" ]] || die "apt-get source fetched"$'\n'"$got"$'\n'"expected"$'\n'"$expected"
	while IFS=$'\t' read -r name digest; do
		verify "$dest/$name" "$digest"
		case $name in
		*.dsc | *.debian.tar.* | *.diff.gz) role=packaging ;;
		*) role=source ;;
		esac
		input "$name" "$role" "$repo/$directory/$name" "$dest/$name"
	done < <(jq -r '.fetch.files[] | [.name, .digest] | @tsv' "$plan")
	;;
git)
	read -r repo commit vendoring main < <(jq -r '.fetch | [.repository, .commit, .vendoring, .mainModule] | join(" ")' "$plan")
	fetch_git "$repo" "$commit" "$dest"
	vendor_go "$dest" "$main" "$vendoring" "$(jq -c .expect "$plan")"
	;;
bundle)
	while IFS= read -r part; do
		case $(jq -r .type <<<"$part") in
		git)
			repo=$(jq -r .repository <<<"$part")
			mapfile -t subpaths < <(jq -r '.subpaths[]' <<<"$part")
			fetch_git "$repo" "$(jq -r .commit <<<"$part")" "$dest/$(basename "$repo")" "${subpaths[@]}"
			;;
		archive)
			url=$(jq -r .url <<<"$part")
			file=$dest/archives/$(basename "$url")
			mkdir -p "$dest/archives"
			[[ ! -e $file ]] || die "two archives named $(basename "$url")"
			curl -fsSL --retry 3 -o "$file" "$url"
			verify "$file" "$(jq -r .digest <<<"$part")"
			input "$(basename "$url")" source "$url" "$file"
			;;
		file)
			path=$(jq -r .path <<<"$part")
			[[ $path =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && $path != *..* ]] || die "unexpected build script path: $path"
			file=$(dirname "$plan")/files/$path
			verify "$file" "$(jq -r .digest <<<"$part")"
			install -D -m 0644 "$file" "$dest/build/$path"
			input "$(basename "$path")" build "$path" "$file"
			;;
		*) die "unknown bundle part: $part" ;;
		esac
	done < <(jq -c '.fetch.parts[]' "$plan")
	;;
*) die "unknown kind $kind" ;;
esac

[[ -z $(jq -r .name "$inputs" | sort | uniq -d) ]] || die "duplicate input names"
jq -n --arg key "$key" --slurpfile identity <(jq .identity "$plan") --slurpfile inputs "$inputs" --argjson vendored "$vendored" \
	'{schemaVersion: 1, kind: "source-image", key: $key, identity: $identity[0], inputs: ($inputs | sort_by(.name)), vendored: $vendored}' \
	>"$out/source/SOURCE.json"

# Deterministic layer: normalized modes with executable bits kept. Ownership and timestamps
# are set when the layer is exported (COPY --chown=0:0, rewrite-timestamp).
find "$out" -type d -exec chmod 0755 {} +
find "$out" -type f -perm /111 -exec chmod 0755 {} +
find "$out" -type f ! -perm /111 -exec chmod 0644 {} +
echo "build-source-image: $root $(jq -r .identity.version "$plan"): $(du -sh "$dest" | cut -f1), $(wc -l <"$inputs") inputs" >&2
