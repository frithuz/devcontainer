#!/usr/bin/env bash
# Smoke tests (docs/maintenance.md#preflight-checks-testsmokesh). Runs inside the image as root,
# and runs each part once as root and once as agent:
#
# - lookup: under `env -i` with only HOME and the default PATH, the way GitHub Actions sees the
#   image. Every command must run, and each pinned tool must report the version its stage pins.
# - environment: the image's ENV with only PATH reset. pnpm, Go, the shared directories, the
#   sandbox contract, sudo, and the locale.
#
# The preflight stage runs it in the build. Against any image, from the repository root:
#
#   docker run --rm --user root --network none \
#     --mount type=bind,source="$PWD",target=/mnt/src,readonly \
#     devcontainer:local bash /mnt/src/test/smoke.sh
#
# Pinned tools come from scripts/legal-components.yaml, and their expected versions from the
# Dockerfile, both read relative to this script. Every check runs even after a failure, and the
# exit status is 1 if any failed.
set -uo pipefail

readonly default_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

self=$(realpath "$0")
readonly self
src=$(dirname "$(dirname "$self")")
readonly src dockerfile=$src/Dockerfile components=$src/scripts/legal-components.yaml

failures=0
label=

pass() {
	echo "ok - $label: $*"
}

fail() {
	echo "not ok - $label: $*"
	failures=$((failures + 1))
}

# check <description> <command...>: passes when the command succeeds; shows its output otherwise.
check() {
	local description=$1 out
	shift
	if out=$("$@" 2>&1 </dev/null); then
		pass "$description"
	else
		fail "$description"
		[[ -z $out ]] || sed 's/^/#   /' <<<"$out"
	fi
}

# expect <description> <expected> <actual>
expect() {
	if [[ $3 == "$2" ]]; then
		pass "$1"
	else
		fail "$1: expected '$2', got '$3'"
	fi
}

# First dotted version number, as collect-legal.sh reads it.
version_in() {
	grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$1" | head -1
}

# The version a stage pins: the first version number in its FROM tag (golang:1.27-trixie gives
# 1.27), or for a stage that builds from a module, the first @vX.Y.Z or =vX.Y.Z in its body.
pinned_version() {
	awk -v stage="$1" '
		toupper($1) == "FROM" {
			in_stage = tolower($(NF - 1)) == "as" && $NF == stage
			if (in_stage) {
				ref = $2
				sub(/@.*/, "", ref)
				if (ref ~ /:[^\/]*$/) {
					sub(/.*:/, "", ref)
					if (match(ref, /[0-9]+(\.[0-9]+)*/)) {
						print substr(ref, RSTART, RLENGTH)
						exit
					}
				}
			}
			next
		}
		in_stage && match($0, /[@=]v?[0-9]+\.[0-9]+(\.[0-9]+)?/) {
			version = substr($0, RSTART + 1, RLENGTH - 1)
			sub(/^v/, "", version)
			print version
			exit
		}
	' "$dockerfile"
}

lookup() {
	local name stage version_cmd cmd path out version expected words
	# Every copied component from scripts/legal-components.yaml. Image tools resolve from
	# /usr/local/bin; the base stage's files stay where Ubuntu put them.
	while IFS=$'\t' read -r -u 3 name stage version_cmd; do
		read -ra words <<<"$version_cmd"
		cmd=${words[0]}
		if ! path=$(command -v "$cmd"); then
			fail "$name: $cmd isn't on the default PATH"
			continue
		fi
		if [[ $stage != base && $path != /usr/local/bin/$cmd ]]; then
			fail "$name: $cmd resolves to $path, not /usr/local/bin/$cmd"
			continue
		fi
		if ! out=$("${words[@]}" 2>&1 </dev/null); then
			fail "$name: '$version_cmd' failed"
			sed 's/^/#   /' <<<"$out"
			continue
		fi
		version=$(version_in "$out")
		# Other components copied from the same stage (npm from node) have their own versions.
		if [[ $name != "$stage" ]]; then
			pass "$name ${version:-(no version)}"
			continue
		fi
		expected=$(pinned_version "$stage")
		if [[ -z $expected ]]; then
			fail "$name: no pinned version found for stage $stage in the Dockerfile"
		elif [[ $version == "$expected" || $version == "$expected".* ]]; then
			pass "$name $version, pinned $expected"
		else
			fail "$name: '$version_cmd' reports '${version:-no version}', but stage $stage pins $expected"
		fi
	done 3< <(yq -r '.components[] | [.name, .stage, .version] | @tsv' "$components")

	# Everything else the image provides: apt packages, aliases, and unpinned installs.
	local -a commands=(
		'bash --version'
		'sh -c :'
		'curl --version'
		'git --version'
		'ssh -V'
		'less --version'
		'sudo --version'
		'locale'
		'docker --version'
		'docker buildx version'
		'docker compose version'
		'dockerd --version'
		'containerd --version'
		'runc --version'
		'gh --version'
		'claude --version'
		'codex --version'
		'gofmt -l /usr/local/go/src/errors'
		'python --version'
		'pip --version'
		'npx --version'
		'uvx --version'
		'pn --version'
	)
	for cmd in "${commands[@]}"; do
		read -ra words <<<"$cmd"
		check "$cmd" "${words[@]}"
	done

	# Never run: it would start a daemon.
	expect "start-dockerd resolves" /usr/local/bin/start-dockerd "$(command -v start-dockerd)"

	# pnpm picks its command from argv[0], so each alias must reach a hard link of that name.
	for name in pn pnpx pnx; do
		path=$(readlink -f "$(command -v "$name")")
		if [[ $path == /opt/pnpm/$name && $path -ef /opt/pnpm/pnpm ]]; then
			pass "$name is a hard link of pnpm"
		else
			fail "$name resolves to ${path:-nothing}, not a hard link /opt/pnpm/$name"
		fi
	done

	# Chained, so the installers' self-updates repoint the inner link (docs/architecture.md#default-path).
	for name in claude codex; do
		expect "$name links to agent's installer link" "/home/agent/.local/bin/$name" "$(readlink "/usr/local/bin/$name")"
		path=$(readlink -f "/usr/local/bin/$name")
		if [[ $path == /home/agent/* && -x $path ]]; then
			pass "$name resolves to $path"
		else
			fail "$name resolves to ${path:-nothing}, not an executable in agent's home"
		fi
	done

	# A missing shared library shows up only on import (docs/architecture.md#binary-compatibility).
	check "python imports every lib-dynload module" python3 - <<'EOF'
import importlib, pathlib, sysconfig

dynload = pathlib.Path(sysconfig.get_path("platstdlib"), "lib-dynload")
modules = sorted({so.name.split(".", 1)[0] for so in dynload.glob("*.so")})
failed = []
for module in modules:
    try:
        importlib.import_module(module)
    except Exception as e:
        failed.append(f"{module}: {e}")
if not modules or failed:
    raise SystemExit("\n".join(failed) or f"no modules in {dynload}")
EOF
}

environment() {
	local home dir file out user
	user=$(id -un)

	expect "BASH_ENV" /etc/devcontainer/env.sh "${BASH_ENV:-}"
	expect "bash loads BASH_ENV" 1 "$(bash -c 'printf %s "${__DEVCONTAINER_ENV_SH:-}"' 2>&1)"
	expect "bash starts silently" "" "$(bash -c : 2>&1)"

	# Set through ENV, so they hold for every user and every HOME (docs/architecture.md#pnpm-configuration).
	for home in "$HOME" ""; do
		expect "pnpm global bin dir (HOME='$home')" /usr/local/bin "$(HOME=$home pnpm bin -g 2>&1)"
		out=$(HOME=$home pnpm root -g 2>&1)
		[[ $out == /usr/local/share/pnpm/global/* ]] && pass "pnpm global dir (HOME='$home')" ||
			fail "pnpm global dir (HOME='$home'): $out"
		out=$(HOME=$home pnpm store path 2>&1)
		[[ $out == /usr/local/share/pnpm/store/* ]] && pass "pnpm store (HOME='$home')" ||
			fail "pnpm store (HOME='$home'): $out"
	done

	expect "GOPATH" /go "$(go env GOPATH 2>&1)"
	expect "GOTOOLCHAIN" local "$(go env GOTOOLCHAIN 2>&1)"
	out=$(go env GOCACHE 2>&1)
	[[ $out == "$HOME"/* ]] && pass "GOCACHE is per-user ($out)" || fail "GOCACHE $out isn't under $HOME"

	# Shared with the other user: created files keep the staff group (docs/architecture.md#shared-writable-directories).
	for dir in /go /go/src /go/bin /usr/local/bin "$PNPM_HOME" "$PNPM_HOME/global" "$PNPM_HOME/store"; do
		if file=$(mktemp -p "$dir" .smoke.XXXXXX 2>&1); then
			expect "$dir is writable, files get group staff" staff "$(stat -c %G "$file")"
			rm -f "$file"
		else
			fail "$dir isn't writable: $file"
		fi
	done

	local module bin=/go/bin/smoke-$user
	module=$(mktemp -d)
	printf 'package main\n\nfunc main() { println("ok") }\n' >"$module/main.go"
	check "go install into GOPATH" bash -c "cd '$module' && go mod init example.com/smoke-$user && go install . && '$bin'"
	rm -rf "$module" "$bin"

	# The sandbox contract (docs/architecture.md#docker-sandboxes-contract).
	expect "agent's passwd entry" agent:1000:1000:/home/agent "$(getent passwd agent | cut -d: -f1,3,4,6)"
	expect "agent's groups" "agent docker staff" "$(id -nG agent | tr ' ' '\n' | sort | xargs)"
	check "no ubuntu user" bash -c '! getent passwd ubuntu'
	check "/bin/sh and /bin/bash are executable" test -x /bin/sh -a -x /bin/bash
	check "CA certificates" test -s /etc/ssl/certs/ca-certificates.crt
	expect "the workspace belongs to agent" agent "$(stat -c %U /home/agent/workspace)"
	for file in claude codex; do
		expect "$file is installed as agent" agent "$(stat -c %U "$(readlink -f "/home/agent/.local/bin/$file")")"
	done

	if [[ $user == agent ]]; then
		expect "passwordless sudo" 0 "$(sudo -n id -u 2>&1)"
		expect "sudo keeps PATH" "/opt/smoke:$PATH" "$(PATH=/opt/smoke:$PATH sudo -n printenv PATH 2>&1)"
		expect "sudo keeps proxy variables" $'http://proxy.invalid:3128\nlocalhost' \
			"$(HTTPS_PROXY=http://proxy.invalid:3128 no_proxy=localhost sudo -n printenv HTTPS_PROXY no_proxy 2>&1)"
	else
		check "sudoers parses" visudo -c
		expect "/etc/sudoers mode" 440 "$(stat -c %a /etc/sudoers)"
	fi

	expect "LANG" en_US.UTF-8 "${LANG:-}"
	expect "LC_ALL" en_US.UTF-8 "${LC_ALL:-}"
	expect "locale prints no warnings" "" "$(locale 2>&1 >/dev/null)"
	expect "locale charmap" UTF-8 "$(locale charmap 2>&1)"
	expect "perl starts without locale warnings" "" "$(perl -e 1 2>&1)"
	expect "python's locale encoding" utf-8 \
		"$(python3 -c 'import locale; locale.setlocale(locale.LC_ALL, ""); print(locale.getencoding().lower())' 2>&1)"
}

# Re-entered for each part and user: smoke.sh <part> <user>
if (($# == 2)); then
	label="$1 ($2)"
	"$1"
	echo "# $label: $failures failed"
	((failures == 0))
	exit
fi

((EUID == 0)) || {
	echo "smoke: run as root (docker run --user root); it runs each part as agent too" >&2
	exit 2
}
for file in "$dockerfile" "$components"; do
	[[ -r $file ]] || {
		echo "smoke: $file isn't readable; mount the repository, not only test/" >&2
		exit 2
	}
done

status=0
as_agent=(setpriv --reuid=agent --regid=agent --init-groups)
env -i HOME=/root PATH="$default_path" bash "$self" lookup root || status=1
"${as_agent[@]}" env -i HOME=/home/agent PATH="$default_path" bash "$self" lookup agent || status=1
env PATH="$default_path" bash "$self" environment root || status=1
"${as_agent[@]}" env HOME=/home/agent USER=agent LOGNAME=agent PATH="$default_path" \
	bash "$self" environment agent || status=1
exit "$status"
