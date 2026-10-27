#!/usr/bin/env bash
# Assemble /legal from what the image's sources provide:
# - fetch license files for components that ship none, at the installed version;
# - write Debian-format copyright files for apt packages that ship none;
# - fetch the license files of every Go module compiled into the image's Go binaries into
#   /legal/go/pkg/mod/<module>@<version>/, where SBOM scanners look for them;
# - write /legal/manifest.tsv covering every component in the image, and
#   /legal/sbom/devcontainer.cdx.json for the components SBOM scanners can't identify on
#   their own. BuildKit's Syft scanner reads SBOM files it finds in the image, so they reach
#   the image's SBOM attestation;
# - fail on executables that no package or listed component accounts for.
# Runs as root after all installs. Missing notices for a top-level component fail the build;
# gaps in bundled dependencies are reported but don't (yet) fail it.
#
# Usage: collect-legal.sh <Dockerfile> <config dir> <gh stage output dir>
# config dir: the Dockerfile's config stage output, with legal-components.json and
#   license-evidence.json (scripts/*.yaml, validated against their schemas).
# LEGAL_GO_MODCACHE: module download cache (a build cache mount; not part of the image).
set -euo pipefail

readonly dockerfile=${1:?usage: collect-legal.sh <Dockerfile> <config dir> <gh-dir>}
readonly components=${2:?}/legal-components.json evidence_json=$2/license-evidence.json
readonly gh_dir=${3:?}
readonly legal=/legal
readonly attribution=$legal/attribution
readonly go_modcache=${LEGAL_GO_MODCACHE:-/var/cache/legal-go-mod}
arch=$(dpkg --print-architecture)
readonly arch

rows=$(mktemp)
sbom_rows=$(mktemp)
# Paths accounted for by a listed component, for the unowned-executable check.
covered=()
errors=0
gaps=0

error() {
	echo "collect-legal: ERROR: $*" >&2
	errors=$((errors + 1))
}

gap() {
	echo "collect-legal: gap: $*" >&2
	gaps=$((gaps + 1))
}

# row <component> <version> <architecture> <license> <notices> <source>
row() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$rows"
}

# sbom <type> <name> <version> <purl> <license> <installed file|-> <vcs url|-> <distribution url|-> <source sha256|-> [cpe]
sbom() {
	local sha=-
	[[ $6 != - ]] && sha=$(sha256sum "$6" | cut -d' ' -f1)
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$sha" "$7" "$8" "$9" "${10:--}" >>"$sbom_rows"
}

# Go's module cache path encoding: an uppercase letter becomes '!' plus its lowercase.
go_escape() {
	# shellcheck disable=SC2001 # \L (lowercase the match) has no parameter-expansion form.
	sed 's/[A-Z]/!\L&/g' <<<"$1"
}

# dep5_copyright <package> <repository> <tag> <license> <file>...: write a Debian
# machine-readable copyright file for a package that ships none, from upstream license files.
dep5_copyright() {
	local pkg=$1 repo=$2 tag=$3 license=$4 file
	shift 4
	mkdir -p "/usr/share/doc/$pkg"
	{
		printf 'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n'
		printf 'Upstream-Name: %s\nSource: https://github.com/%s/tree/%s\n' "${repo#*/}" "$repo" "$tag"
		printf 'Comment: The package ships no copyright file. Written by devcontainer'"'"'s\n'
		printf ' scripts/collect-legal.sh from the license files at the upstream tag of the\n installed version.\n'
		for file in "$@"; do
			[[ $(basename "$file") == LICENSE ]] && continue
			printf ' .\n %s:\n' "$(basename "$file")"
			sed -e 's/^[[:space:]]*$/./' -e 's/^/ /' "$file"
		done
		printf '\nFiles: *\nCopyright: see the upstream repository\nLicense: %s\n' "$license"
		sed -e 's/^[[:space:]]*$/./' -e 's/^/ /' "$(dirname "$1")/LICENSE"
	} >"/usr/share/doc/$pkg/copyright"
}

# First dotted version number in a command's output.
version_of() {
	bash -c "$1" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# Expand notice globs; print the existing paths, space-separated.
notices_of() {
	local pattern path found=()
	for pattern in $1; do
		for path in $pattern; do
			[[ -e $path ]] && found+=("$path")
		done
	done
	echo "${found[*]}"
}

# Every package.json that belongs to an installed package (node_modules/<name> or
# node_modules/@scope/<name>, at any depth), not helper manifests inside a package.
package_manifests() {
	find "$1" -name package.json | sort | while IFS= read -r manifest; do
		local dir parent
		dir=$(dirname "$manifest")
		parent=$(dirname "$dir")
		if [[ $parent == */node_modules ]] || [[ $parent == */node_modules/@* && $(dirname "$parent") == */node_modules ]]; then
			echo "$manifest"
		fi
	done
}

# fetch <component> <repo> <ref> <license> <path>...: download upstream files into
# attribution/<component>/ and record them in its SOURCE file.
fetch() {
	local comp=$1 repo=$2 ref=$3 license=$4 dir=$attribution/$1 path file
	shift 4
	mkdir -p "$dir"
	{
		echo "component: $comp"
		echo "repository: https://github.com/$repo"
		echo "ref: $ref"
		echo "license: $license"
		echo "files:"
	} >"$dir/SOURCE"
	for path in "$@"; do
		file=$dir/$(basename "$path")
		curl -fsSL --retry 3 -o "$file" "https://raw.githubusercontent.com/$repo/$ref/$path"
		printf '  - path: %s\n    url: https://github.com/%s/blob/%s/%s\n    sha256: %s\n' \
			"$path" "$repo" "$ref" "$path" "$(sha256sum "$file" | cut -d' ' -f1)" >>"$dir/SOURCE"
	done
}

# Upstream stage references, read from the Dockerfile so digests live in one place. A tag
# marks an upstream image, not a stage name.
declare -A stage_ref
while read -r ref name; do
	stage_ref[$name]=$ref
done < <(awk 'toupper($1) == "FROM" && $2 ~ /:/ && toupper($3) == "AS" { print $2, $4 }' "$dockerfile")
base_ref=${stage_ref[debian]:-}
[[ -n $base_ref ]] || error "no debian stage in the Dockerfile"
# Files the base image ships outside any package are listed under the "base" stage.
stage_ref[base]=$base_ref

# --- This project -------------------------------------------------------------------------
project_files=(/etc/devcontainer/env.sh /usr/local/bin/start-dockerd /etc/sudoers.d/agent
	/legal/LICENSE /legal/README.md /legal/SOURCE.md)
cmp -s "$legal/LICENSE" "$(dirname "$dockerfile")/LICENSE" || error "/legal/LICENSE differs from the repository LICENSE"
row devcontainer "${REVISION:-unknown}" all CC0-1.0 "$legal/LICENSE" "project files: ${project_files[*]}"
sbom application devcontainer "${REVISION:-unknown}" "pkg:generic/devcontainer@${REVISION:-unknown}" CC0-1.0 - - - -

# --- Debian base and apt packages ---------------------------------------------------------
declare -A deb_uri
while read -r uri file _ hash; do
	deb_uri[$file]="${uri//\'/} $hash"
done <"$legal/provenance/apt-uris.txt"

# Docker's packages ship no copyright file, so take the notices from the upstream
# repository at the installed version: <repository> <tag prefix> <files>.
declare -A deb_upstream=(
	["docker-ce"]="moby/moby docker-v LICENSE NOTICE"
	["docker-ce-cli"]="docker/cli v LICENSE NOTICE"
	["docker-buildx-plugin"]="docker/buildx v LICENSE"
	["docker-compose-plugin"]="docker/compose v LICENSE NOTICE"
)

# Read the package list on fd 3, so nothing in the loop body can consume it.
while IFS=$'\t' read -r -u 3 status pkg name version pkg_arch src src_version; do
	[[ $status == ii* ]] || continue
	# This project's own packages are covered by the project row.
	[[ $name == devcontainer-* ]] && continue
	debfile="${name}_${version//:/%3a}_${pkg_arch}.deb"
	provenance=${deb_uri[$debfile]:-}
	[[ -n $provenance ]] || error "no download provenance for $pkg $version"
	license=
	notices=/usr/share/doc/$name/copyright
	if [[ ! -e $notices ]]; then
		notices=$(dpkg -L "$pkg" | grep -m1 '/copyright$' || true)
	fi
	if [[ -n $notices ]]; then
		# Debian machine-readable copyright files declare License: short names; others don't.
		license=$(awk 'NR == 1 && !/^Format:/ { exit } /^License:/ { sub(/^License:[ \t]*/, ""); if ($0 != "") print }' \
			"$notices" | sort -u | paste -sd';' - | sed 's/;/; /g')
	elif [[ -n ${deb_upstream[$name]:-} ]]; then
		read -r repo prefix files <<<"${deb_upstream[$name]}"
		upstream=${version#*:}
		upstream=${upstream%%-*}
		# shellcheck disable=SC2086 # files is a space-separated list.
		fetch "$name" "$repo" "$prefix$upstream" Apache-2.0 $files
		# Where Debian tooling and SBOM scanners look for a package's license.
		mapfile -t fetched < <(find "$attribution/$name" -type f -not -name SOURCE | sort)
		dep5_copyright "$name" "$repo" "$prefix$upstream" Apache-2.0 "${fetched[@]}"
		license=Apache-2.0
		notices="/usr/share/doc/$name/copyright ${fetched[*]}"
	else
		error "no copyright file for $pkg"
	fi
	row "deb:$name" "$version" "$pkg_arch" "${license:-NOASSERTION}" "${notices:--}" \
		"src:$src=${src_version:-$version} $provenance base:$base_ref"
done 3< <(dpkg-query -W -f '${db:Status-Abbrev}\t${binary:Package}\t${Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\n')

# --- Tools copied from pinned images, or built from Go modules or source ------------------
# Binaries built here with go install, by name, for the copyleft module check below.
declare -A compiled_bins
# One line per component on fd 3 (lists space-separated, absent fields "-"), so the version
# commands can't consume it.
while IFS=$'\t' read -r -u 3 comp stage install license version_cmd notice_globs paths upstream purl; do
	if [[ $install == go-install ]]; then
		# Built in its own stage: the module, version, and go.sum hash are in the binary.
		awk -v s="$stage" 'toupper($1) == "FROM" && toupper($3) == "AS" && $4 == s { found = 1 } END { exit !found }' "$dockerfile" ||
			error "$comp: no stage '$stage' in the Dockerfile"
		read -r mod_path mod_ver mod_sum < <(go version -m "${paths%% *}" | awk -F'\t' '$2 == "mod" { print $3, $4, $5; exit }') || true
		[[ -n ${mod_path:-} ]] || error "$comp: ${paths%% *} has no Go module build info"
		provenance="go-install:${mod_path:-}@${mod_ver:-} ${mod_sum:-} stage:$stage"
		distribution=-
		for bin_path in $paths; do
			compiled_bins[$(basename "$bin_path")]=$comp
		done
	elif [[ $install == source-build ]]; then
		# Compiled in its own stage, which records the archive it built in its SOURCE file.
		awk -v s="$stage" 'toupper($1) == "FROM" && toupper($3) == "AS" && $4 == s { found = 1 } END { exit !found }' "$dockerfile" ||
			error "$comp: no stage '$stage' in the Dockerfile"
		# The build script that compiled it goes into its source image too.
		read -r src_url src_sha build_script build_sha < <(awk '$1 == "source:" { u = $2 } $1 == "sha256:" { h = $2 }
			$1 == "build-script:" { s = $2; d = $3 } END { print u, h, s, d }' "$attribution/$comp/SOURCE" 2>/dev/null) || true
		[[ -n ${src_url:-} && -n ${src_sha:-} ]] || error "$comp: $attribution/$comp/SOURCE records no source archive"
		[[ -n ${build_script:-} && ${build_sha:-} == sha256:* ]] || error "$comp: $attribution/$comp/SOURCE records no build script"
		provenance="source:${src_url:-} sha256:${src_sha:-} build-script:${build_script:-} ${build_sha:-} stage:$stage"
		distribution=-
	elif [[ $install == release ]]; then
		# Unpacked from upstream's release archive in its own stage, which records the archive in
		# its SOURCE file.
		awk -v s="$stage" 'toupper($1) == "FROM" && toupper($3) == "AS" && $4 == s { found = 1 } END { exit !found }' "$dockerfile" ||
			error "$comp: no stage '$stage' in the Dockerfile"
		read -r rel_url rel_sha < <(awk '$1 == "release:" { u = $2 } $1 == "sha256:" { h = $2 } END { print u, h }' \
			"$attribution/$comp/SOURCE" 2>/dev/null) || true
		[[ -n ${rel_url:-} && -n ${rel_sha:-} ]] || error "$comp: $attribution/$comp/SOURCE records no release archive"
		provenance="release:${rel_url:-} sha256:${rel_sha:-} stage:$stage"
		distribution=${rel_url:-}
	else
		ref=${stage_ref[$stage]:-}
		[[ -n $ref ]] || error "$comp: no upstream stage '$stage' in the Dockerfile"
		provenance="image:$ref"
		distribution=${ref%%@*}
	fi
	version=$(version_of "$version_cmd")
	[[ -n $version ]] || error "$comp: '$version_cmd' printed no version"
	if [[ $upstream != - ]]; then
		# shellcheck disable=SC2086 # "<repo> <tag> <files...>" splits into fetch's arguments.
		set -- ${upstream//\{version\}/$version}
		repo=$1 tag=$2
		shift 2
		fetch "$comp" "$repo" "$tag" "$license" "$@"
	fi
	notices=$(notices_of "$notice_globs")
	[[ -n $notices ]] || error "$comp: no notice files match $notice_globs"
	row "$comp" "$version" "$arch" "$license" "$notices" "$provenance paths: $paths"
	if [[ $install == source-build ]]; then
		# Libraries compiled into it: "embedded: <name> <version> <license> <url> sha256:<hex>", with
		# their notices in <name>/. Their archives are part of its source.
		while read -r _ e_name e_version e_license e_url e_sha; do
			e_notices=$(find "$attribution/$comp/$e_name" -type f 2>/dev/null | sort | paste -sd' ' -)
			[[ -n $e_notices ]] || error "$comp: no notices for embedded $e_name in $attribution/$comp/$e_name"
			row "$e_name" "$e_version" "$arch" "$e_license" "${e_notices:--}" "embedded-in:$comp source:$e_url $e_sha"
			sbom library "$e_name" "$e_version" "pkg:generic/$e_name@$e_version" "$e_license" - \
				"$e_url" - "${e_sha#sha256:}"
		done < <(awk '$1 == "embedded:"' "$attribution/$comp/SOURCE")
	fi
	# shellcheck disable=SC2206 # paths is a space-separated list.
	covered+=($paths)
	if [[ $purl != - ]]; then
		sbom application "$comp" "$version" "${purl//\{version\}/$version}" "$license" "${paths%% *}" - "$distribution" -
	fi
done 3< <(jq -r '.components[] | [.name, .stage, .install // "image", .license, .version, (.notices | join(" ")), (.paths | join(" ")),
	(if .upstream then [.upstream.repository, .upstream.tag] + .upstream.files | join(" ") else "-" end), .purl // "-"] | @tsv' "$components")

# --- GitHub CLI release tarball -----------------------------------------------------------
mkdir -p "$attribution/gh"
cp "$gh_dir/LICENSE" "$attribution/gh/LICENSE"
gh_version=$(cat "$gh_dir/VERSION")
read -r gh_url gh_digest <"$gh_dir/SOURCE"
printf 'component: gh\nrepository: https://github.com/cli/cli\nref: v%s\nlicense: MIT\nfiles:\n  - path: LICENSE\n    url: %s (from the release tarball)\n' \
	"$gh_version" "$gh_url" >"$attribution/gh/SOURCE"
row gh "$gh_version" "$arch" MIT "$attribution/gh/LICENSE" "release:$gh_url $gh_digest"
covered+=(/usr/local/bin/gh)

# --- Libraries compiled into node and python ----------------------------------------------
# node reports its bundled libraries in process.versions; their notices are in Node's LICENSE.
# <name> <license> <CPE vendor:product, or -> per key. ABI and data versions aren't listed.
declare -A node_lib=(
	["acorn"]="acorn MIT -" ["ada"]="ada Apache-2.0_OR_MIT -" ["amaro"]="amaro MIT -"
	["ares"]="c-ares MIT c-ares:c-ares" ["brotli"]="brotli MIT google:brotli"
	["icu"]="icu Unicode-3.0 unicode:international_components_for_unicode" ["libffi"]="libffi MIT libffi_project:libffi"
	["lief"]="lief Apache-2.0 -" ["llhttp"]="llhttp MIT llhttp:llhttp" ["merve"]="merve Apache-2.0_OR_MIT -"
	["nbytes"]="nbytes MIT -" ["ncrypto"]="ncrypto MIT -" ["nghttp2"]="nghttp2 MIT nghttp2:nghttp2"
	["nghttp3"]="nghttp3 MIT ngtcp2:nghttp3"
	["ngtcp2"]="ngtcp2 MIT ngtcp2:ngtcp2" ["openssl"]="openssl Apache-2.0 openssl:openssl"
	["simdjson"]="simdjson Apache-2.0_OR_MIT -" ["simdutf"]="simdutf Apache-2.0_OR_MIT -"
	["sqlite"]="sqlite blessing sqlite:sqlite" ["undici"]="undici MIT nodejs:undici" ["uv"]="libuv MIT_AND_BSD-2-Clause_AND_ISC libuv:libuv"
	["uvwasi"]="uvwasi MIT -" ["v8"]="v8 BSD-3-Clause google:v8" ["zlib"]="zlib Zlib zlib:zlib"
	["zstd"]="zstd BSD-3-Clause_OR_GPL-2.0-only facebook:zstandard"
)
while IFS=$'\t' read -r key version; do
	case $key in node | modules | napi | unicode | cldr | tz) continue ;; esac
	[[ -n $version ]] || continue
	read -r name license cpe <<<"${node_lib[$key]:-$key NOASSERTION -}"
	license=${license//_/ }
	[[ $license == NOASSERTION ]] && gap "node bundles $key $version with no known license; recorded as NOASSERTION"
	[[ $cpe == - ]] || cpe="cpe:2.3:a:$cpe:$version:*:*:*:*:*:*:*"
	row "node:$name" "$version" "$arch" "$license" "$attribution/node/LICENSE" "embedded-in:node process.versions.$key"
	sbom library "$name" "$version" "pkg:generic/$name@$version" "$license" - - - - "$cpe"
done < <(node -p 'Object.entries(process.versions).map(e => e.join("\t")).join("\n")')

# python's pyexpat is built against its bundled copy of expat.
expat_version=$(python3 -c 'import pyexpat; print(pyexpat.EXPAT_VERSION.removeprefix("expat_"))')
fetch expat libexpat/libexpat "R_${expat_version//./_}" MIT expat/COPYING
row python:expat "$expat_version" "$arch" MIT "$attribution/expat/COPYING" "embedded-in:python pyexpat.EXPAT_VERSION"
sbom library expat "$expat_version" "pkg:generic/expat@$expat_version" MIT - "https://github.com/libexpat/libexpat/tree/R_${expat_version//./_}" - - \
	"cpe:2.3:a:libexpat_project:libexpat:$expat_version:*:*:*:*:*:*:*"

# --- npm packages bundled with pnpm -------------------------------------------------------
# The deprecated object and array forms ({"type": "Apache 2.0"}, as qrcode-terminal uses) become
# an expression of their types, with spaces made into SPDX-style hyphens.
# shellcheck disable=SC2016 # jq program, not shell.
package_fields='[.name, .version, (.license // .licenses // "NOASSERTION" |
	if type == "string" then . else [.] | flatten | map(if type == "object" then .type else . end | gsub(" "; "-")) | join(" OR ") end)] | join(" ")'
for parent in pnpm:/opt/pnpm/dist/node_modules; do
	owner=${parent%%:*}
	root=${parent#*:}
	while IFS= read -r manifest; do
		dir=${manifest%/package.json}
		read -r name version license < <(jq -r "$package_fields" "$manifest")
		notices=$(find "$dir" -maxdepth 1 -type f -iregex '.*/\(licen[cs]e\|copying\|notice\)[^/]*' | sort | paste -sd' ' -)
		if [[ -z $notices ]]; then
			gap "$owner bundles $name@$version ($license) without a license file"
			notices=$manifest
		fi
		row "$owner:$name" "$version" all "$license" "$notices" "embedded-in:$owner path:$dir"
	done < <(package_manifests "$root")
done

# --- Go modules compiled into the image's Go binaries --------------------------------------
# go version -m lists every module a Go binary was built from. Fetch each module through the
# Go proxy (verified against sum.golang.org) and keep only its license files, at the module
# cache layout SBOM scanners search: /legal/go/pkg/mod/<module>@<version>/.
go_mods=$(mktemp)
go version -m /usr/bin /usr/sbin /usr/lib /usr/libexec /usr/local/bin /opt /home/agent/.local/share 2>/dev/null |
	awk -F'\t' '
		function flush() { if (path != "") print bin "\t" kind "\t" path "\t" ver; path = "" }
		# A binary with a "path" but no "mod" line was built outside module mode; its main
		# package path stands in for the main module, as SBOM scanners treat it.
		function done_bin() { flush(); if (bin != "" && !has_mod && main != "") print bin "\tmod\t" main "\t(devel)" }
		/^[^\t]/ { done_bin(); bin = $0; sub(/: go[0-9].*$/, "", bin); has_mod = 0; main = ""; next }
		$2 == "path" { main = $3; next }
		$2 == "mod" || $2 == "dep" { flush(); kind = $2; path = $3; ver = $4; if ($2 == "mod") has_mod = 1; next }
		$2 == "=>" { path = $3; ver = $4; next }
		END { done_bin() }' |
	grep -v $'\t/usr/local/go/' | sort -u >"$go_mods"

declare -A mod_bins mod_kind mod_rev
# -X linker flags: '-X <pkg>.Version=<v>', '-X=<pkg>.Version=<v>', optionally quoted.
x_version_flag='-X[= ]"?[^ "=]+/[^/ "=]+\.[Vv]ersion='
x_flag_module='s/^-X[= ]"?//; s#/[^/]+\.[Vv]ersion=$##'
x_flag_value='s/.*=//; s/\\*$//'
while IFS=$'\t' read -r bin kind path ver; do
	# The commit a main module was built from, for scripts/plan-sources.sh to check its tag
	# against: vcs.revision, or a -X <pkg>.GitCommit=/Revision= linker flag (may be abbreviated).
	if [[ $kind == mod ]]; then
		rev=$(go version -m "$bin" | awk -F'\t' '$2 == "build" && $3 ~ /^vcs\.revision=/ { sub(/^vcs\.revision=/, "", $3); print $3; exit }') || true
		if [[ -z $rev ]]; then
			rev=$(go version -m "$bin" | grep -oE -- '-X[= ][\\"]*[^ "=\\]+\.(GitCommit|Revision)=[0-9a-f]{7,40}' | head -1 | sed 's/.*=//') || true
		fi
	fi
	# A main module built outside module mode reports "(devel)" (and, built from a file list,
	# the path "command-line-arguments"). Like SBOM scanners, take its module path and version
	# from a -X <module>/<package>.Version=<v> linker flag.
	if [[ $kind == mod && $ver == "(devel)" ]]; then
		ldflags=$(go version -m "$bin" | grep -- '-ldflags' | head -1) || true
		if [[ $path == command-line-arguments ]]; then
			derived=$(grep -oE -- "$x_version_flag" <<<"$ldflags" | head -1 | sed -E "$x_flag_module") || true
			[[ -n $derived ]] && path=$derived
		fi
		inferred=$(grep -oE "$path/[^= ]*[Vv]ersion=[0-9][^\" ]*" <<<"$ldflags" | head -1 | sed "$x_flag_value") || true
		[[ -n $inferred ]] && ver=v$inferred
	fi
	key="$path@$ver"
	mod_bins[$key]="${mod_bins[$key]:+${mod_bins[$key]},}$(basename "$bin")"
	if [[ $kind == mod ]]; then
		mod_kind[$key]=main
		[[ -n $rev && -z ${mod_rev[$key]:-} ]] && mod_rev[$key]=$rev
	fi
done <"$go_mods"
rm -f "$go_mods"

go_downloads=$(mktemp)
mapfile -t go_wanted < <(printf '%s\n' "${!mod_bins[@]}" | grep -vE '@(\(devel\))?$' | sort)
printf '%s\n' "${go_wanted[@]}" |
	GOMODCACHE=$go_modcache GOFLAGS=-mod=mod GOTOOLCHAIN=local xargs -n 50 go mod download -json >"$go_downloads" 2>/dev/null || true

declare -A mod_dir mod_error
# shellcheck disable=SC2016 # jq program, not shell.
# Empty fields become "-": read with IFS=$'\t' would merge consecutive tabs.
download_fields='[.Path, .Version, (.Dir // "-"), (.Error // "-")] | @tsv'
while IFS=$'\t' read -r path ver dir err; do
	if [[ $dir != - ]]; then
		mod_dir["$path@$ver"]=$dir
	else
		mod_error["$path@$ver"]=$err
	fi
done < <(jq -r "$download_fields" "$go_downloads")
rm -f "$go_downloads"

# License and notice documents. Files with these names that aren't documents are skipped: Go
# source (license.go, notice_test.go), and the license tooling in hidden directories, config
# files, and scripts (.github/workflows/license-check.yml, licenserc.yml, script/licenses).
license_files='.*/\(licen[cs]e\|copying\|notice\|patents\|unlicense\)[^/]*'
not_documents=(-not -name '*.go' -not -iname '*.yml' -not -iname '*.yaml' -not -iname '*.json' -not -iname '*.tmpl')

# Reviewed license texts to add (scripts/license-evidence.yaml), per module path: one line per
# check or file ("reviewed <file> <sha256>", "include <path> <as>", "add <as> <url> <sha256>").
declare -A evidence evidence_used
while IFS=$'\t' read -r mod line; do
	evidence[$mod]+=$line$'\n'
done < <(jq -r '.modules[] | .module as $m |
	(.reviewed[] | [$m, "reviewed", .file, .sha256]), (.include[]? | [$m, "include", .path, .as]),
	(.add[]? | [$m, "add", .as, .url, .sha256]) | @tsv' "$evidence_json")
for key in "${go_wanted[@]}"; do
	path=${key%@*} ver=${key##*@}
	dest=$legal/go/pkg/mod/$(go_escape "$path")@$(go_escape "$ver")
	files=()
	base=${mod_dir[$key]:-}
	if [[ -n $base ]]; then
		# Every license file in the module, paths kept relative: subdirectories often hold code
		# under another license (forked Go code, ported C). Syft reads only the top level, so
		# these don't reach the attestation unless scripts/license-evidence.yaml adds them there.
		mapfile -t files < <(find "$base" -type f -iregex "$license_files" "${not_documents[@]}" \
			-not -path "$base/.*" -not -path "$base/*/.*" -not -path "$base/testdata/*" -not -path "$base/*/testdata/*" | sort)
		for i in "${!files[@]}"; do
			[[ $(head -c 2 "${files[i]}") != '#!' ]] || unset 'files[i]'
		done
		source="proxy:https://proxy.golang.org/$(go_escape "$path")/@v/$(go_escape "$ver").zip"
	else
		# Not on the proxy (for example an unpublished commit): fall back to a component's
		# fetched attribution for the same repository (ignoring a /vN major-version suffix).
		repo_path=$(sed -E 's#/v[0-9]+$##' <<<"$path")
		for dir in "$attribution"/*/; do
			if grep -qxF "repository: https://$repo_path" "$dir/SOURCE" 2>/dev/null; then
				mapfile -t files < <(find "$dir" -maxdepth 1 -type f -not -name SOURCE | sort)
				base=${dir%/}
				source="attribution:${dir%/} ($(sed -n 's/^ref: //p' "$dir/SOURCE"); proxy: ${mod_error[$key]:-not found})"
				break
			fi
		done
	fi
	if ((${#files[@]} == 0)); then
		if [[ -n $base ]]; then
			reason="none in the module"
		else
			reason=${mod_error[$key]:-not downloaded}
		fi
		gap "Go module $key (in ${mod_bins[$key]}) has no license files: $reason"
		row "go-module:$path" "$ver" all NOASSERTION - "embedded-in:${mod_bins[$key]} ${mod_kind[$key]:+main-module }${mod_rev[$key]:+revision:${mod_rev[$key]} }${mod_error[$key]:+error:${mod_error[$key]}}"
		continue
	fi
	for file in "${files[@]}"; do
		install -D -m 0644 "$file" "$dest/${file#"$base"/}"
	done
	# A binary upstream built carries upstream's obligation to publish its copyleft modules'
	# source; one built here carries ours, and no source root covers a go-install component
	# (docs/legal.md#copyleft-components).
	for bin in ${mod_bins[$key]//,/ }; do
		if [[ -n ${compiled_bins[$bin]:-} ]] && grep -qE 'Mozilla Public License|GNU (Lesser |Library |Affero )?General Public License' "${files[@]}"; then
			error "$key, compiled into ${compiled_bins[$bin]} by go install, is under a copyleft license: install upstream's binary instead, or add a root to scripts/source-roots.yaml"
		fi
	done
	# Reviewed additions, beside the upstream files, at the top where Syft reads them.
	# An entry applies to the versions that have any of its reviewed files: a version without
	# them (an older one, before the forked code was added) has nothing to add.
	added=
	applies=false
	if [[ -n ${evidence[$path]:-} ]]; then
		while IFS=$'\t' read -r action arg1 _; do
			[[ $action == reviewed && -f $base/$arg1 ]] && applies=true
		done < <(printf '%s' "${evidence[$path]}")
		$applies || echo "collect-legal: $key has none of the files reviewed in scripts/license-evidence.yaml; not applied" >&2
	fi
	if $applies; then
		evidence_used[$path]=1
		[[ $source == proxy:* ]] || error "$key: scripts/license-evidence.yaml needs the module from the Go proxy"
		while IFS=$'\t' read -r action arg1 arg2 arg3; do
			case $action in
			reviewed)
				[[ $(sha256sum "$base/$arg1" 2>/dev/null | cut -d' ' -f1) == "$arg2" ]] ||
					error "$key: $arg1 isn't the text reviewed in scripts/license-evidence.yaml; review the entry again"
				;;
			include)
				if [[ -e $dest/$arg2 || ! -f $base/$arg1 ]]; then
					error "$key: can't include $arg1 as $arg2 (missing, or the name is taken)"
				else
					install -m 0644 "$base/$arg1" "$dest/$arg2"
					added+="added:$arg2=$arg1 "
				fi
				;;
			add)
				if [[ -e $dest/$arg1 ]]; then
					error "$key: can't add $arg1: the module already has a file by that name"
				elif curl -fsSL --retry 3 -o "$dest/$arg1" "$arg2" && [[ $(sha256sum "$dest/$arg1" | cut -d' ' -f1) == "$arg3" ]]; then
					added+="added:$arg1=$arg2 "
				else
					rm -f "$dest/$arg1"
					error "$key: $arg2 doesn't match its sha256 in scripts/license-evidence.yaml"
				fi
				;;
			esac
		done < <(printf '%s' "${evidence[$path]}")
	fi
	notices=$(find "$dest" -type f | sort | paste -sd' ' -)
	row "go-module:$path" "$ver" all NOASSERTION "$notices" "embedded-in:${mod_bins[$key]} ${mod_kind[$key]:+main-module }${mod_rev[$key]:+revision:${mod_rev[$key]} }$added$source"
done
for mod in "${!evidence[@]}"; do
	[[ -n ${evidence_used[$mod]:-} ]] || error "$mod: no version in the image has the files reviewed in scripts/license-evidence.yaml; update or remove its entry"
done

# --- Executables nobody accounts for ------------------------------------------------------
# Every ELF file must belong to an apt package or a listed component; the base image can ship
# unpackaged binaries (Ubuntu's shipped /usr/bin/pebble), which would otherwise go unrecorded.
owned=$(mktemp)
dpkg-query -W -f '${binary:Package}\n' | xargs dpkg-query -L 2>/dev/null |
	sed -E 's#^/(bin|sbin|lib|lib32|lib64|libx32)/#/usr/\1/#' | sort -u >"$owned"
while IFS= read -r -d '' file; do
	LC_ALL=C read -r -n 4 magic <"$file" || true
	[[ $magic == $'\x7fELF' ]] || continue
	grep -qxF "$file" "$owned" && continue
	for prefix in "${covered[@]}"; do
		[[ $file == "$prefix" || $file == "$prefix"/* ]] && continue 2
	done
	error "$file is not owned by any package or listed component; add it to scripts/legal-components.yaml"
done < <(find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /mnt -o -path /tmp -o -path "$legal" -o -path "$go_modcache" \) -prune \
	-o -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) -print0)
rm -f "$owned"

# --- Write the manifest -------------------------------------------------------------------
{
	printf 'component\tversion\tarchitecture\tlicense\tnotices\tsource\n'
	sort -t$'\t' -k1,1 "$rows"
} >"$legal/manifest.tsv"
rm -f "$rows"

# CycloneDX components for what scanners can't identify. Deterministic: no serial number or
# timestamp, components sorted by purl.
mkdir -p "$legal/sbom"
# shellcheck disable=SC2016 # jq program, not shell.
cyclonedx='
[inputs | split("\t") | {
	type: .[0], name: .[1], version: .[2], purl: .[3], "bom-ref": .[3],
	licenses: (if .[4] == "NOASSERTION" then [] else [{expression: .[4]}] end),
	hashes: (if .[6] == "-" then [] else [{alg: "SHA-256", content: .[6]}] end),
	cpe: (if .[10] == "-" then null else .[10] end),
	properties: (if .[5] == "-" then [] else [{name: "devcontainer:path", value: .[5]}] end),
	externalReferences: (
		(if .[7] == "-" then [] else [{type: "vcs", url: .[7]}] end) +
		(if .[8] == "-" then [] else [{type: "distribution", url: .[8]}
			+ (if .[9] == "-" then {} else {hashes: [{alg: "SHA-256", content: .[9]}]} end)] end))
} | with_entries(select(.value != [] and .value != null))] | sort_by(.purl) | {
	bomFormat: "CycloneDX", specVersion: "1.6", version: 1,
	metadata: {component: {type: "container", name: "devcontainer", version: $revision}},
	components: .
}'
jq -nR --arg revision "${REVISION:-unknown}" "$cyclonedx" <"$sbom_rows" >"$legal/sbom/devcontainer.cdx.json"
rm -f "$sbom_rows"

chown -R root:root "$legal"
chmod -R u=rwX,go=rX "$legal"

echo "collect-legal: $(($(wc -l <"$legal/manifest.tsv") - 1)) components, $gaps gaps, $errors errors" >&2
if ((errors > 0)); then
	exit 1
fi
