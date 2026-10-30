#!/usr/bin/env bash
# The image's system, after apt-bootstrap.sh (Dockerfile's image stage, step 2): apt packages, the
# locale, the shared directories, and the agent user. The agent CLIs come with the sandbox kits.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
arch=$(dpkg --print-architecture)

apt-get upgrade -y
apt-get install -y --no-install-recommends \
	bash ca-certificates curl less locales neovim openssh-client passwd sudo-rs \
	media-types netbase tzdata \
	bat fd-find file fzf lsd ripgrep tmux unzip xz-utils zip \
	lsof netcat-openbsd openssl procps socat toybox trippy \
	bubblewrap \
	libatomic1 \
	libcurl4t64 libpcre2-8-0 \
	libbz2-1.0 libdb5.3t64 libffi8 libgdbm6t64 liblzma5 libmpdec4 libncursesw6 \
	libreadline8t64 libsqlite3-0 libssl3t64 libtinfo6 libuuid1 libzstd1 zlib1g

# The base image keeps only root, nonroot, shadow, and nobody: add Debian's staff group
# (base-passwd's GID) before Docker's packages add the docker group.
groupadd --gid 50 staff

# Docker Engine from Docker's repository.
# shellcheck source=/dev/null
. /etc/os-release
cat >/etc/apt/sources.list.d/docker.sources <<SOURCES
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
SOURCES
# DHI's repository carries its own builds of these packages, versioned without Docker's
# ~debian suffix, so they'd sort higher and win. They have no maintainer scripts, so the
# docker group isn't created. Docker's repository takes precedence for them.
cat >/etc/apt/preferences.d/docker <<'PREFERENCES'
Package: docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin containerd.io
Pin: origin download.docker.com
Pin-Priority: 900
PREFERENCES
apt-get update
apt-get install -y --no-install-recommends \
	docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin containerd.io

# DHI's base can carry packages at versions its repository no longer serves. DHI moved its builds
# from +dhiN to +deb13u0+dhiN, which sorts lower, and rebuilt some of them, but the base still
# shipped a few under the old names. Move each one to the repository's build of the same release,
# allowing the downgrade, so the image holds only packages the provenance below can record. Once
# the base matches its repository, this finds nothing.
mapfile -t names < <(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" { print $2 }')
declare -A served=()
while IFS='|' read -r name version _; do
	served["${name// /}=${version// /}"]=1
done < <(apt-cache madison "${names[@]}")
moves=()
unserved=()
while read -r name version; do
	if [[ -n ${served["$name=$version"]:-} ]]; then
		continue
	fi
	if [[ $version =~ ^(.*)\+(dhi[0-9]+)$ && -n ${served["$name=${BASH_REMATCH[1]}+deb13u0+${BASH_REMATCH[2]}"]:-} ]]; then
		moves+=("$name=${BASH_REMATCH[1]}+deb13u0+${BASH_REMATCH[2]}")
	else
		unserved+=("$name=$version")
	fi
done < <(dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' | awk '$1 == "ii" { print $2, $3 }')
if ((${#unserved[@]})); then
	echo "No repository serves these installed versions, or a +deb13u0 build of them:" >&2
	printf '  %s\n' "${unserved[@]}" >&2
	exit 1
fi
if ((${#moves[@]})); then
	echo "Moving to the repository's builds: ${moves[*]}"
	# Installing a package by name marks it manually installed, so restore the auto marks.
	mapfile -t auto < <(apt-mark showauto "${moves[@]%%=*}")
	apt-get install -y --no-install-recommends --allow-downgrades "${moves[@]}"
	if ((${#auto[@]})); then
		apt-mark auto "${auto[@]}"
	fi
fi

# No apt installs follow, so record the exact .deb URL and checksum of every installed
# package (base image included) from the package lists.
mkdir -p /legal/provenance
mapfile -t installed < <(dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package}=${Version}\n' | awk '$1 == "ii" { print $2 }')
apt-get download --print-uris "${installed[@]}" >/legal/provenance/apt-uris.txt
recorded=$(wc -l </legal/provenance/apt-uris.txt)
if ((recorded != ${#installed[@]})); then
	echo "apt-uris.txt has $recorded entries for ${#installed[@]} packages" >&2
	exit 1
fi

# The locale the ENV below selects, and the copied shared libraries. Debian's locale-gen ignores
# arguments and builds what /etc/locale.gen enables.
sed -i 's/^# \(en_US\.UTF-8 UTF-8\)$/\1/' /etc/locale.gen
if ! grep -qx 'en_US.UTF-8 UTF-8' /etc/locale.gen; then
	echo 'en_US.UTF-8 is not enabled in /etc/locale.gen' >&2
	exit 1
fi
locale-gen
ldconfig

# Shared GOPATH: root:staff, group-writable, setgid.
mkdir -p /go/src /go/bin
chown -R root:staff /go
chmod -R 775 /go
chmod 2775 /go /go/src /go/bin
go version

# The agent user (UID 1000, the sandbox contract), in docker and staff, with bash as its login
# shell; passwordless sudo that keeps PATH. The base image has no user to rename.
useradd --uid 1000 --user-group --create-home --home-dir /home/agent \
	--groups docker,staff --shell /bin/bash agent
# root's login shell is /bin/sh in the base image.
usermod --shell /bin/bash root
# Debian's sudo-rs installs only sudo-rs and visudo-rs, and ships no sudoers: link the upstream
# names, and write a sudoers without secure_path.
ln -s /usr/lib/cargo/bin/sudo /usr/bin/sudo
ln -s /usr/lib/cargo/bin/visudo /usr/sbin/visudo
cat >/etc/sudoers <<'SUDOERS'
Defaults env_reset
Defaults use_pty
root ALL=(ALL:ALL) ALL
@includedir /etc/sudoers.d
SUDOERS
cat >/etc/sudoers.d/agent <<'SUDOERS'
Defaults env_keep += "PATH HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY http_proxy https_proxy ftp_proxy no_proxy"
agent ALL=(ALL) NOPASSWD:ALL
SUDOERS
chmod 0440 /etc/sudoers /etc/sudoers.d/agent
visudo -c
install -d -o agent -g agent /home/agent/workspace

# Debian renames fd and bat to avoid name clashes; restore the upstream names.
ln -s /usr/bin/fdfind /usr/local/bin/fd
ln -s /usr/bin/batcat /usr/local/bin/bat
# toybox picks its command from argv[0]; only these replace tools the image leaves out.
ln -s /usr/bin/toybox /usr/local/bin/netstat
ln -s /usr/bin/toybox /usr/local/bin/ifconfig

# Shared /usr/local/bin and PNPM_HOME: the directories only, never recursively.
chown root:staff /usr/local/bin
chmod 2775 /usr/local/bin
readonly pnpm_home=/usr/local/share/pnpm
mkdir -p "$pnpm_home/global" "$pnpm_home/store"
chown -R root:staff "$pnpm_home"
chmod 2775 "$pnpm_home" "$pnpm_home/global" "$pnpm_home/store"

# Runs a command as agent, with agent's environment.
as_agent() {
	setpriv --reuid=agent --regid=agent --init-groups env HOME=/home/agent USER=agent LOGNAME=agent "$@"
}

# gh-stack as agent's gh extension, laid out as `gh extension install github/gh-stack` would: a
# directory with the binary and a manifest that makes it a binary extension. The binary is a link
# to the root-owned /usr/local/bin/gh-stack, so the manifest pins it: `gh extension upgrade`
# leaves it alone instead of failing to overwrite it.
gh_stack_version=$(go version -m /usr/local/bin/gh-stack | awk '$1 == "mod" && $2 == "github.com/github/gh-stack" { print $3 }')
if [[ $gh_stack_version != v* ]]; then
	echo "gh-stack's build info has no module version: '$gh_stack_version'" >&2
	exit 1
fi
readonly gh_stack=/home/agent/.local/share/gh/extensions/gh-stack
as_agent mkdir -p "$gh_stack"
as_agent ln -s /usr/local/bin/gh-stack "$gh_stack/gh-stack"
as_agent tee "$gh_stack/manifest.yml" >/dev/null <<MANIFEST
owner: github
name: gh-stack
host: github.com
tag: $gh_stack_version
ispinned: true
path: $gh_stack/gh-stack
MANIFEST
