#!/usr/bin/env bash
# Exercise the registry decision without contacting a registry or compiling Git.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case ${SCENARIO:?} in
same) printf '{"annotations":{"dev.frithuz.git.source-sha256":"%s"}}\n' "$CHECKSUM" ;;
changed) printf '{"annotations":{"dev.frithuz.git.source-sha256":"different"}}\n' ;;
missing) echo 'manifest unknown' >&2; exit 1 ;;
notfound) echo "ERROR: $4: not found" >&2; exit 1 ;;
auth) echo 'unauthorized' >&2; exit 1 ;;
network) echo 'connection refused' >&2; exit 1 ;;
malformed) echo '{}' ;;
*) echo 'unexpected registry call' >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"
CHECKSUM=$(awk -F= 'NF == 2 && $1 == "ARG SHA256" { print $2 }' Dockerfile.git)
export CHECKSUM
for scenario in same changed missing notfound; do
	result=$(SCENARIO=$scenario bash scripts/git-image-changes.sh)
	expected=true
	[[ $scenario != same ]] || expected=false
	grep -qx "build=$expected" <<<"$result"
done
for scenario in auth network malformed; do
	if SCENARIO=$scenario bash scripts/git-image-changes.sh >"$work/output" 2>"$work/error"; then
		echo "$scenario should fail closed" >&2
		exit 1
	fi
	if grep -q '^build=' "$work/output"; then
		echo "$scenario emitted a build decision" >&2
		exit 1
	fi
done
result=$(SCENARIO=unexpected FORCE=true bash scripts/git-image-changes.sh)
grep -qx 'build=true' <<<"$result"
echo 'Git image decisions passed'
