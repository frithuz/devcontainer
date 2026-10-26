#!/usr/bin/env bash
# Docker-in-Docker checks (docs/architecture.md#docker). Runs inside the image as agent, in a
# privileged container with no host socket and its own volumes for the daemon's data:
#
#   docker run --rm --privileged \
#     --mount type=volume,target=/var/lib/docker --mount type=volume,target=/var/lib/containerd \
#     --mount type=bind,source="$PWD/test",target=/mnt/test,readonly \
#     devcontainer:local bash /mnt/test/runtime.sh
#
# Never run it on a macOS host (docs/usage.md#docker-on-macos-hosts). The first failure stops it,
# because each check needs the ones before it.
set -euo pipefail

readonly socket=/var/run/docker.sock
readonly tag=runtime-check:local

die() {
	echo "runtime: $*" >&2
	exit 1
}

work=$(mktemp -d)
daemon_started=false
on_exit() {
	local status=$?
	if ((status != 0)) && $daemon_started; then
		echo "runtime: last lines of the daemon log:" >&2
		sudo -n tail -n 50 /var/log/dockerd.log >&2 || true
	fi
	rm -rf "$work"
}
trap on_exit EXIT

# Otherwise start-dockerd finds another daemon and does nothing, and the checks below would test
# that daemon instead (docs/architecture.md#docker).
[[ -z ${DOCKER_HOST:-} ]] || die "DOCKER_HOST is set ($DOCKER_HOST); run without it"
[[ ! -e $socket ]] || die "$socket already exists; run without a host socket mount"
for dir in /var/lib/docker /var/lib/containerd; do
	mountpoint -q "$dir" || die "$dir isn't a mounted volume; the daemon's data must never be a layer"
done
echo "ok - no other daemon, and the daemon's data is on volumes"

daemon_started=true
start-dockerd
echo "ok - start-dockerd started a daemon"

# The daemon names itself after the host it runs on, which is this container.
pgrep -x dockerd >/dev/null || die "no dockerd process in this container"
name=$(docker info --format '{{.Name}}')
[[ $name == "$(hostname)" ]] || die "the daemon answering is $name, not this container's ($(hostname))"
echo "ok - the daemon answering is this container's"

# agent reaches it through the docker group, without sudo.
docker version
root_dir=$(docker info --format '{{.DockerRootDir}}')
[[ $root_dir == /var/lib/docker ]] || die "the daemon's root is $root_dir, not /var/lib/docker"
echo "ok - agent reaches the daemon without sudo, storage driver $(docker info --format '{{.Driver}}')"

docker buildx version
docker compose version

# Built from a static binary already in the image, so nothing is pulled. Running it uses the
# default bridge network, which needs the daemon's iptables setup.
cp "$(command -v shfmt)" "$work/shfmt"
cat >"$work/Dockerfile" <<'EOF'
FROM scratch
COPY shfmt /shfmt
ENTRYPOINT ["/shfmt"]
EOF
docker build --quiet --tag "$tag" "$work"
echo "ok - built an image"

expected=$(shfmt --version)
actual=$(docker run --rm "$tag" --version)
[[ $actual == "$expected" ]] || die "the container printed $actual, not $expected"
echo "ok - ran a container on the default bridge network"

cat >"$work/compose.yaml" <<EOF
services:
  check:
    image: $tag
    command: [--version]
EOF
actual=$(docker compose --file "$work/compose.yaml" --project-name runtime-check run --rm check)
docker compose --file "$work/compose.yaml" --project-name runtime-check down
[[ $actual == "$expected" ]] || die "the compose service printed $actual, not $expected"
echo "ok - ran a compose service"
