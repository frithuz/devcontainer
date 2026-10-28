#!/usr/bin/env bash
# Write /legal/source.tsv: where the source of every copyleft component in /legal/manifest.tsv was
# published when the image was built, one row per file with its URL and digest
# (docs/legal.md#copyleft-components):
# - apt: every copyleft or non-machine-readable package's source package (.dsc and archives), as
#   apt resolves it from the deb-src repositories in scripts/source-apt.yaml, verified against
#   their signed indexes;
# - compiled here: the archive a component was compiled from, the archives of the libraries
#   compiled into it, and the script that controlled the build, at this build's commit.
# Every other copyleft component must be covered by a license election, or the build fails. Go
# modules' licenses aren't in manifest.tsv; scripts/collect-legal.sh keeps copyleft ones out of
# the binaries built here.
# Runs as root after scripts/collect-legal.sh.
#
# Usage: collect-source.sh <config dir>
# config dir: the Dockerfile's config stage output, with source-apt.json and
#   license-elections.json (scripts/*.yaml, validated against their schemas).
# LEGAL_APT_LISTS: the deb-src index cache (a build cache mount; not part of the image).
# REVISION, REPOSITORY_URL: this build's commit and this repository's web URL, for build scripts'
#   permalinks. Without them, a build script's URL is its path in the repository.
set -euo pipefail

readonly config=${1:?usage: collect-source.sh <config dir>}
readonly apt_json=$config/source-apt.json elections_json=$config/license-elections.json
readonly legal=/legal
readonly manifest=$legal/manifest.tsv
readonly lists=${LEGAL_APT_LISTS:-/var/cache/legal-apt-lists}
# Licenses that owe source. NOASSERTION (an apt copyright file that isn't machine-readable) can't
# be ruled out, so it owes source too.
readonly copyleft='GPL|MPL|EPL|CDDL|EUPL|NOASSERTION'

errors=0
error() {
	echo "collect-source: ERROR: $*" >&2
	errors=$((errors + 1))
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rows=$work/rows.tsv
: >"$rows"

# row <source> <version> <url> <digest (<algorithm>:<hex>)> <components, comma-separated>
row() {
	printf '%s\t%s\t%s\t%s\t%s\n' "$@" >>"$rows"
}

mapfile -t elected < <(jq -r '.elections[].components[]' "$elections_json")
is_elected() {
	local pattern
	for pattern in "${elected[@]}"; do
		# shellcheck disable=SC2053 # components are globs.
		[[ $1 == $pattern ]] && return 0
	done
	return 1
}

# --- apt -------------------------------------------------------------------------------------
# Copyleft packages, by source package and version: "<source>\t<version>\t<components>".
apt_needed=$work/apt.tsv
awk -F'\t' -v OFS='\t' -v re="$copyleft" 'NR > 1 && $1 ~ /^deb:/ && $4 ~ re {
		split($6, f, " "); src = substr(f[1], 5); eq = index(src, "=")
		print substr(src, 1, eq - 1), substr(src, eq + 1), $1 }' "$manifest" |
	sort -u | awk -F'\t' -v OFS='\t' '
		{ key = $1 "\t" $2; covers[key] = covers[key] (covers[key] == "" ? "" : ",") $3 }
		END { for (key in covers) print key, covers[key] }' | sort >"$apt_needed"

for pattern in "${elected[@]}"; do
	[[ $pattern == deb:* ]] && error "$pattern: elections don't apply to apt packages"
done

if [[ -s $apt_needed ]]; then
	# A private apt configuration with only the deb-src repositories, so the image's own sources
	# and lists are left alone. The lists persist in the build cache; apt fetches only what changed.
	mkdir -p "$lists/partial" "$work/parts" "$work/cache/archives/partial"
	jq -r '.repositories[] | "Types: deb-src", "URIs: \(.url)", "Suites: \(.suites | join(" "))",
		"Components: \(.components | join(" "))", "Signed-By: \(.signedBy)", ""' "$apt_json" >"$work/source.sources"
	apt_opts=(
		-o "Dir::Etc::SourceList=$work/source.sources" -o "Dir::Etc::SourceParts=$work/parts"
		-o "Dir::State::Lists=$lists" -o "Dir::Cache=$work/cache" -o Acquire::Languages=none
		-o APT::Sandbox::User=root
	)
	apt-get "${apt_opts[@]}" -qq update
	while IFS=$'\t' read -r -u 3 pkg version covers; do
		# Each file as "'<url>' <name> <size> <ALGORITHM>:<hex>", with the strongest hash the
		# repository's signed index lists (SHA512 for Debian's and DHI's).
		if ! uris=$(apt-get "${apt_opts[@]}" -qq --print-uris --only-source source "$pkg=$version" 2>"$work/apt.err"); then
			error "$pkg $version ($covers): no source package in scripts/source-apt.yaml's repositories: $(tr '\n' ' ' <"$work/apt.err")"
			continue
		fi
		found=0
		while read -r url _ _ hash; do
			[[ $url == \'*\' ]] || continue
			if [[ ! $hash =~ ^SHA(256|512):[0-9a-f]+$ ]]; then
				error "$pkg $version: apt reports no SHA-256 or SHA-512 for $url"
				continue
			fi
			row "$pkg" "$version" "${url//\'/}" "sha${hash#SHA}" "$covers"
			found=$((found + 1))
		done <<<"$uris"
		((found > 0)) || error "$pkg $version ($covers): apt lists no source files"
	done 3<"$apt_needed"
fi

# --- Compiled here, and everything else ------------------------------------------------------
# Components compiled in the Dockerfile record "source:<url> sha256:<hex>" and
# "build-script:<path> sha256:<hex>"; the libraries compiled into them, "embedded-in:<component>
# source:<url> sha256:<hex>". Every other copyleft component must be elected.
script_url() {
	if [[ -n ${REVISION:-} && -n ${REPOSITORY_URL:-} ]]; then
		echo "$REPOSITORY_URL/blob/$REVISION/$1"
	else
		echo "$1"
	fi
}

while IFS=$'\t' read -r -u 3 comp version license source; do
	if is_elected "$comp"; then
		continue
	fi
	if [[ ! $source =~ (^| )source:([^ ]+)\ sha256:([0-9a-f]{64}) ]]; then
		error "$comp $version ($license) owes source but records no source archive: install upstream's binary instead, or add an election to scripts/license-elections.yaml"
		continue
	fi
	row "$comp" "$version" "${BASH_REMATCH[2]}" "sha256:${BASH_REMATCH[3]}" "$comp"
	if [[ $source =~ build-script:([^ ]+)\ sha256:([0-9a-f]{64}) ]]; then
		row "$comp" "$version" "$(script_url "${BASH_REMATCH[1]}")" "sha256:${BASH_REMATCH[2]}" "$comp"
	fi
	# Libraries compiled into it are part of its source, whatever their own license.
	while IFS=$'\t' read -r e_comp e_source; do
		if [[ $e_source =~ source:([^ ]+)\ sha256:([0-9a-f]{64}) ]]; then
			row "$comp" "$version" "${BASH_REMATCH[1]}" "sha256:${BASH_REMATCH[2]}" "$e_comp"
		else
			error "$e_comp, compiled into $comp, records no source archive"
		fi
	done < <(awk -F'\t' -v OFS='\t' -v c="$comp" 'NR > 1 && $6 ~ ("(^| )embedded-in:" c "( |$)") { print $1, $6 }' "$manifest")
done 3< <(awk -F'\t' -v OFS='\t' -v re="$copyleft" 'NR > 1 && $1 !~ /^(deb|go-module):/ && $4 ~ re && $6 !~ /(^| )embedded-in:/ {
	print $1, $2, $4, $6 }' "$manifest")

# Copyleft libraries compiled into something must be covered by what they're compiled into.
while IFS=$'\t' read -r comp license into; do
	is_elected "$comp" && continue
	awk -F'\t' -v c="$into" '$1 == c { found = 1 } END { exit !found }' "$rows" ||
		error "$comp ($license) is compiled into $into, which records no source"
done < <(awk -F'\t' -v OFS='\t' -v re="$copyleft" 'NR > 1 && $1 !~ /^(deb|go-module):/ && $4 ~ re && match($6, /embedded-in:[^ ]+/) {
	n = split(substr($6, RSTART + 12, RLENGTH - 12), into, ","); for (i = 1; i <= n; i++) print $1, $4, into[i] }' "$manifest")

# --- Write -----------------------------------------------------------------------------------
{
	printf 'source\tversion\turl\tdigest\tcomponents\n'
	sort -u "$rows"
} >"$legal/source.tsv"
chmod 0644 "$legal/source.tsv"

echo "collect-source: $(cut -f1,2 "$rows" | sort -u | wc -l) sources, $(wc -l <"$rows") files, $errors errors" >&2
if ((errors > 0)); then
	exit 1
fi
