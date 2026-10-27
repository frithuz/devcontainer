# The image's system, after apt-bootstrap.nu (Dockerfile's image stage, step 2): apt packages, the
# locale, the shared directories, and the agent user. The agent CLIs come with the sandbox kits.
$env.DEBIAN_FRONTEND = 'noninteractive'
let arch = dpkg --print-architecture | str trim

apt-get upgrade -y
let packages = [
  bash ca-certificates curl less locales neovim openssh-client passwd sudo-rs
  media-types netbase tzdata
  bat fd-find file fzf lsd ripgrep tmux unzip xz-utils zip
  lsof netcat-openbsd openssl procps toybox trippy
  bubblewrap
  libatomic1
  libcurl4t64 libpcre2-8-0
  libbz2-1.0 libdb5.3t64 libffi8 libgdbm6t64 liblzma5 libmpdec4 libncursesw6
  libreadline8t64 libsqlite3-0 libssl3t64 libtinfo6 libuuid1 libzstd1 zlib1g
]
apt-get install -y --no-install-recommends ...$packages

# The base image keeps only root, nonroot, shadow, and nobody: add Debian's staff group
# (base-passwd's GID) before Docker's packages add the docker group.
groupadd --gid 50 staff

# Docker Engine from Docker's repository.
let codename = open --raw /etc/os-release | lines
  | where $it starts-with 'VERSION_CODENAME=' | first
  | str replace 'VERSION_CODENAME=' '' | str trim --char '"'
$"Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ($codename)
Components: stable
Architectures: ($arch)
Signed-By: /etc/apt/keyrings/docker.asc
" | save /etc/apt/sources.list.d/docker.sources
apt-get update
(apt-get install -y --no-install-recommends
  docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin containerd.io)

# No apt installs follow, so record the exact .deb URL and checksum of every installed
# package (base image included) from the package lists.
mkdir /legal/provenance
let installed = dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package}=${Version}\n' | lines
  | each {|line| $line | split row --regex '\s+' }
  | where {|fields| $fields.0 == 'ii' }
  | each {|fields| $fields.1 }
apt-get download --print-uris ...$installed | save /legal/provenance/apt-uris.txt
let recorded = open --raw /legal/provenance/apt-uris.txt | lines | length
if $recorded != ($installed | length) {
  error make {msg: $"apt-uris.txt has ($recorded) entries for ($installed | length) packages"}
}

# The locale the ENV below selects, and the copied shared libraries. Debian's locale-gen ignores
# arguments and builds what /etc/locale.gen enables.
let locale_gen = open --raw /etc/locale.gen
  | str replace --regex '(?m)^# (en_US\.UTF-8 UTF-8)$' '$1'
$locale_gen | save --force /etc/locale.gen
if not (open --raw /etc/locale.gen | lines | any {|line| $line == 'en_US.UTF-8 UTF-8' }) {
  error make {msg: 'en_US.UTF-8 is not enabled in /etc/locale.gen'}
}
locale-gen
ldconfig

# Shared GOPATH: root:staff, group-writable, setgid.
mkdir /go/src /go/bin
chown -R root:staff /go
chmod -R 775 /go
chmod 2775 /go /go/src /go/bin
go version

# The agent user (UID 1000, the sandbox contract), in docker and staff, with nu as its login
# shell; passwordless sudo that keeps PATH. The base image has no user to rename.
"/usr/local/bin/nu\n" | save --append /etc/shells
(useradd --uid 1000 --user-group --create-home --home-dir /home/agent
  --groups docker,staff --shell /usr/local/bin/nu agent)
# root's login shell is /bin/sh in the base image.
usermod --shell /bin/bash root
# Debian's sudo-rs installs only sudo-rs and visudo-rs, and ships no sudoers: link the upstream
# names, and write a sudoers without secure_path.
ln -s /usr/lib/cargo/bin/sudo /usr/bin/sudo
ln -s /usr/lib/cargo/bin/visudo /usr/sbin/visudo
r#'Defaults env_reset
Defaults use_pty
root ALL=(ALL:ALL) ALL
@includedir /etc/sudoers.d
'# | save /etc/sudoers
r#'Defaults env_keep += "PATH HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY http_proxy https_proxy ftp_proxy no_proxy"
agent ALL=(ALL) NOPASSWD:ALL
'# | save /etc/sudoers.d/agent
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
let pnpm_home = '/usr/local/share/pnpm'
mkdir $"($pnpm_home)/global" $"($pnpm_home)/store"
chown -R root:staff $pnpm_home
chmod 2775 $pnpm_home $"($pnpm_home)/global" $"($pnpm_home)/store"

# Runs a command as agent, with agent's environment.
let as_agent = [--reuid=agent --regid=agent --init-groups env HOME=/home/agent USER=agent LOGNAME=agent]

# gh-stack as agent's gh extension, laid out as `gh extension install github/gh-stack` would: a
# directory with the binary and a manifest that makes it a binary extension. The binary is a link
# to the root-owned /usr/local/bin/gh-stack, so the manifest pins it: `gh extension upgrade`
# leaves it alone instead of failing to overwrite it.
let gh_stack_version = go version -m /usr/local/bin/gh-stack | lines
  | parse --regex '^\s+mod\s+github\.com/github/gh-stack\s+(?<version>v\S+)' | get version | first
let gh_stack = '/home/agent/.local/share/gh/extensions/gh-stack'
setpriv ...$as_agent mkdir -p $gh_stack
setpriv ...$as_agent ln -s /usr/local/bin/gh-stack $"($gh_stack)/gh-stack"
$"owner: github
name: gh-stack
host: github.com
tag: ($gh_stack_version)
ispinned: true
path: ($gh_stack)/gh-stack
" | setpriv ...$as_agent tee $"($gh_stack)/manifest.yml" | ignore
