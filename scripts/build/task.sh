#!/usr/bin/env bash
# Downloads Task's release archive for TARGETARCH, checks it against the SHA-256 the stage pins
# for that architecture, and unpacks the binary and its LICENSE to /opt/task (Dockerfile's task
# stage). SOURCE records the archive, for scripts/collect-legal.sh (install: release).
set -euo pipefail

case $TARGETARCH in
amd64) expected=$SHA256_AMD64 ;;
arm64) expected=$SHA256_ARM64 ;;
*)
	echo "task: no pinned archive for $TARGETARCH" >&2
	exit 1
	;;
esac
url=https://github.com/go-task/task/releases/download/v$VERSION/task_linux_$TARGETARCH.tar.gz
work=$(mktemp -d)
curl -fsSL --retry 3 -o "$work/task.tar.gz" "$url"
digest=$(sha256sum "$work/task.tar.gz" | cut -d' ' -f1)
if [[ $digest != "$expected" ]]; then
	echo "task: $url has sha256 $digest, expected $expected" >&2
	exit 1
fi
mkdir /opt/task
tar -xzf "$work/task.tar.gz" -C /opt/task task LICENSE
rm -r "$work"
cat >/opt/task/SOURCE <<SOURCE
component: task
repository: https://github.com/go-task/task
ref: v$VERSION
release: $url
sha256: $digest
SOURCE
